import { ForbiddenException, Injectable } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { PermissionService } from '../../common/services/permission.service';
import { KoreaderRouletteRepository, rouletteKey } from './koreader-roulette.repository';
import { KoreaderHubService } from './koreader-hub.service';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { BookRequestService } from '../book-request/book-request.service';
import { rankRoulette, type TasteSignal } from './koreader-roulette-ranker';
import { dedupeDiscovery, type DiscoveryBook } from './koreader-discovery.service';
import { KoreaderCatalogBooksQueryDto } from './dto/koreader-catalog-query.dto';
import type { RouletteDecisionDto, RouletteQueryDto, RouletteQueueDto, RouletteTasteDto } from './dto/koreader-roulette.dto';
import type { RouletteRecord } from './koreader-roulette.repository';
// Cards ranked per build, how many a call may send, and when the deck is rebuilt.
const DECK_SIZE = 30;
const DECK_MAX_SEND = 20;
const DECK_REFILL_BELOW = 5;
const DECK_TTL_MS = 20 * 60 * 1000;
const DECK_CACHE_MAX = 200;
const SYNOPSIS_LIMIT = 8;
type RouletteSeed = { title: string; authors?: string[]; genres?: string[]; description?: string };
type RouletteDeck = { builtAt: number; cards: DiscoveryBook[]; partial: boolean; onboarded: boolean; feedbackCount: number };
@Injectable()
export class KoreaderRouletteService {
  private readonly decks = new Map<string, RouletteDeck>();
  private readonly building = new Map<string, Promise<RouletteDeck>>();
  constructor(
    private readonly repository: KoreaderRouletteRepository,
    private readonly hub: KoreaderHubService,
    private readonly external: KoreaderExternalCatalogService,
    private readonly catalog: KoreaderCatalogService,
    private readonly requests: KoreaderRequestsService,
    private readonly core: BookRequestService,
    private readonly permissions: PermissionService,
  ) {}
  private access(user: RequestUser) {
    if (!this.permissions.userHas(user, Permission.BookRequestAccess)) throw new ForbiddenException('Book Requests access is required');
  }
  private book(record: RouletteRecord): DiscoveryBook {
    return { ...record.book, authors: record.book.authors ?? [] };
  }
  private async availability(books: DiscoveryBook[], user: RequestUser) {
    return this.core.checkAvailability(
      books.map((book) => ({
        title: book.title,
        author: book.authors[0],
        isbn13: book.isbn13,
        providerKey: book.providerKey,
        providerId: book.providerId,
        mediaKind: 'ebook' as const,
      })),
      user,
    );
  }
  /**
   * Roulette cards for this reader. Ranking takes several catalog searches, so the ranked
   * deck is kept for a while and refilled in the background after decisions; a call then
   * only drops cards decided since and adds synopses. count > 1 serves an offline deck.
   */
  async queue(user: RequestUser, query: Partial<RouletteQueueDto> = {}) {
    this.access(user);
    const count = Math.max(1, Math.min(DECK_MAX_SEND, query.count ?? 1));
    const seed = await this.seed(user, query);
    const deckKey = this.deckKey(user, seed);
    let deck = await this.deck(user, seed, false);
    let decided = await this.repository.decided(user.id, deck.cards.map(rouletteKey));
    let cards = deck.cards.filter((card) => !decided.has(rouletteKey(card)));
    if (!cards.length && Date.now() - deck.builtAt > 1000) {
      deck = await this.deck(user, seed, true);
      decided = await this.repository.decided(user.id, deck.cards.map(rouletteKey));
      cards = deck.cards.filter((card) => !decided.has(rouletteKey(card)));
    } else if (cards.length < DECK_REFILL_BELOW) {
      this.refill(user, seed, deckKey);
    }
    let partial = deck.partial;
    const items = cards.slice(0, count).map((card) => ({ ...card }));
    // Full prose only for the cards being sent, a few at a time; the public work adapter caches it.
    await Promise.all(
      items.slice(0, SYNOPSIS_LIMIT).map(async (card) => {
        if (card.providerKey !== 'openLibrary' || !card.providerId) return;
        try {
          card.description = (await this.external.synopsis(card.providerId)) ?? card.description;
        } catch {
          partial = true;
        }
      }),
    );
    return {
      items: items.map((book) => ({ ...book, rouletteKey: rouletteKey(book) })),
      partial,
      onboarded: deck.onboarded,
      feedbackCount: deck.feedbackCount,
      remaining: cards.length,
      seed: seed?.title,
    };
  }

  private deckKey(user: RequestUser, seed?: RouletteSeed) {
    return user.id + '|' + (seed ? rouletteKey(seed) : '');
  }

  private async seed(user: RequestUser, query: Partial<RouletteQueueDto>): Promise<RouletteSeed | undefined> {
    if (query.seedBookId) {
      const book = await this.catalog.getBookDetail(user, query.seedBookId);
      return { title: book.title, authors: book.authors, genres: book.genres, description: book.description ?? undefined };
    }
    if (query.seedTitle) {
      return { title: query.seedTitle, authors: query.seedAuthor ? [query.seedAuthor] : [], genres: query.seedGenre ? [query.seedGenre] : [] };
    }
    return undefined;
  }

  private async deck(user: RequestUser, seed: RouletteSeed | undefined, rebuild: boolean): Promise<RouletteDeck> {
    const key = this.deckKey(user, seed);
    const cached = this.decks.get(key);
    if (!rebuild && cached && Date.now() - cached.builtAt < DECK_TTL_MS) return cached;
    const running = this.building.get(key);
    if (running) return running;
    const work = this.rank(user, seed)
      .then((deck) => {
        this.decks.delete(key);
        this.decks.set(key, deck);
        // A small bound: one deck per reader plus a few "more like this" decks.
        while (this.decks.size > DECK_CACHE_MAX) this.decks.delete(this.decks.keys().next().value!);
        return deck;
      })
      .finally(() => this.building.delete(key));
    this.building.set(key, work);
    return work;
  }

  private refill(user: RequestUser, seed: RouletteSeed | undefined, key: string) {
    if (this.building.has(key)) return;
    this.deck(user, seed, true).catch(() => undefined);
  }

  private async rank(user: RequestUser, seed?: RouletteSeed): Promise<RouletteDeck> {
    const [records, taste, history] = await Promise.all([
      this.repository.records(user.id),
      this.repository.get(user.id, 'tastes') as Promise<RouletteTasteDto | undefined>,
      this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { size: 10, page: 1, sort: 'recently_read' })),
    ]);
    const signals: TasteSignal[] = records
      .filter((r) => ['match', 'pass'].includes(r.decision))
      .map((r) => ({ book: this.book(r), weight: r.decision === 'match' ? 2 : -2 }));
    const details = await Promise.all(
      history.items
        .filter((b) => b.lastReadAt)
        .slice(0, 10)
        .map((b) => this.catalog.getBookDetail(user, b.id).catch(() => null)),
    );
    for (const book of details)
      if (book)
        signals.push({
          book: { title: book.title, authors: book.authors, genres: book.genres, description: book.description ?? undefined },
          weight:
            book.rating != null
              ? book.rating <= 2
                ? -1.5
                : book.rating >= 4
                  ? 1.8
                  : 0.5
              : history.items.find((item) => item.id === book.id)?.readStatus === 'finished'
                ? 1.2
                : 1,
        });
    if (taste?.genres.length) signals.push({ book: { title: 'Your favorite genres', authors: [], genres: taste.genres }, weight: 1.5 });
    const queries: Array<{ q: string; field: string }> = [];
    if (seed) {
      // "More like this" outweighs the general profile and searches around the seed first.
      signals.push({ book: { ...seed, authors: seed.authors ?? [] }, weight: 6 });
      if (seed.authors?.[0]) queries.push({ q: seed.authors[0], field: 'author' });
      for (const genre of (seed.genres ?? []).filter((g) => !/^(fiction|general|novel|novels)$/i.test(g)).slice(0, 2))
        queries.push({ q: genre, field: 'subject' });
      if (!seed.genres?.length) queries.push({ q: seed.title, field: 'title' });
    }
    const discovery = seed ? { candidates: [] as DiscoveryBook[], partial: false } : await this.hub.discoveryCandidates(user, history, details);
    let partial = discovery.partial;
    for (const genre of (taste?.genres ?? []).slice(0, 3)) queries.push({ q: genre, field: 'subject' });
    for (const favorite of (taste?.favorites ?? []).slice(0, 3)) queries.push({ q: favorite, field: 'title' });
    for (const record of records.filter((r) => r.decision === 'match').slice(0, 2)) {
      if (record.book.genres?.[0]) queries.push({ q: record.book.genres[0], field: 'subject' });
      else if (record.book.authors?.[0]) queries.push({ q: record.book.authors[0], field: 'author' });
    }
    // A changing exploratory genre gives sparse profiles a route beyond their seed authors.
    const exploration = ['Mystery', 'Historical fiction', 'Science fiction', 'Fantasy', 'Adventure', 'Biography'];
    queries.push({ q: exploration[Math.floor(records.length / 5) % exploration.length], field: 'subject' });
    const pools = await Promise.all(
      [...new Map([...queries.slice(0, 7), queries[queries.length - 1]].map((q) => [q.field + ':' + q.q.trim().toLowerCase(), q])).values()].map(
        (q) =>
          this.external
            .search(q.q, q.field, 1, undefined, 'popular', { language: 'en' })
            .then((p) => {
              if (q.field === 'title' && p.items[0] && !seed) signals.push({ book: p.items[0], weight: 1.8 });
              return p.items;
            })
            .catch(() => {
              partial = true;
              return [];
            }),
      ),
    );
    const seedKey = seed ? rouletteKey(seed) : undefined;
    const candidates = dedupeDiscovery([...discovery.candidates, ...pools.flat()])
      .filter((book) => book.title.length <= 500 && (book.authors[0]?.length ?? 0) <= 255 && rouletteKey(book) !== seedKey)
      .slice(0, 150);
    const excluded = await this.repository.excluded(user.id, candidates.map(rouletteKey));
    const skipped = new Set(
      records
        .filter((r) => r.decision === 'skip')
        .slice(0, 50)
        .map((r) => r.key),
    );
    const eligible = candidates.filter((b) => !excluded.has(rouletteKey(b)) && !skipped.has(rouletteKey(b)));
    const availability = eligible.length ? await this.availability(eligible, user) : [];
    const missing = eligible.filter((_b, i) => availability[i] && availability[i].ownedBookId == null && availability[i].existingRequestId == null);
    return {
      builtAt: Date.now(),
      cards: rankRoulette(missing, signals, 'hybrid', DECK_SIZE),
      partial,
      onboarded: !!taste,
      feedbackCount: records.filter((r) => r.decision === 'match' || r.decision === 'pass').length,
    };
  }
  async matches(user: RequestUser, query: RouletteQueryDto) {
    this.access(user);
    const page = await this.repository.matches(user.id, query.page, query.q, query.genre, query.sort);
    const books = page.items.map((r) => this.book(r)),
      availability = books.length ? await this.availability(books, user) : [];
    return {
      ...page,
      items: books.map((book, i) => ({
        ...book,
        matchKey: page.items[i].key,
        availability: availability[i],
        bookId: availability[i]?.ownedBookId ?? undefined,
      })),
      page: query.page,
    };
  }
  async decide(user: RequestUser, input: RouletteDecisionDto) {
    this.access(user);
    const result = await this.repository.decide(user.id, input);
    // Keep the next cards ready: rank again in the background once the deck runs low.
    const key = this.deckKey(user);
    const deck = this.decks.get(key);
    if (deck && deck.cards.length) {
      void this.repository
        .decided(user.id, deck.cards.map(rouletteKey))
        .then((decided) => {
          if (deck.cards.filter((card) => !decided.has(rouletteKey(card))).length < DECK_REFILL_BELOW) this.refill(user, undefined, key);
        })
        .catch(() => undefined);
    }
    return result;
  }
  undo(user: RequestUser, id: string) {
    this.access(user);
    return this.repository.undo(user.id, id);
  }
  history(user: RequestUser, page: number) {
    this.access(user);
    return this.repository.history(user.id, page);
  }
  async tastes(user: RequestUser, input?: RouletteTasteDto) {
    this.access(user);
    if (input) this.decks.delete(this.deckKey(user));
    return input ? this.repository.tastes(user.id, input) : ((await this.repository.get(user.id, 'tastes')) ?? { genres: [], favorites: [] });
  }
  reset(user: RequestUser) {
    this.access(user);
    for (const key of [...this.decks.keys()]) if (key.startsWith(user.id + '|')) this.decks.delete(key);
    return this.repository.reset(user.id);
  }
  async acquire(user: RequestUser, keys: string[]) {
    this.access(user);
    const results: Array<{
      key: string;
      error?: string;
      request?: Awaited<ReturnType<KoreaderRequestsService['create']>>['request'];
      bookId?: number;
    }> = [];
    for (const key of new Set(keys.slice(0, 20))) {
      const row = (await this.repository.get(user.id, 'book:' + key)) as RouletteRecord | undefined;
      if (!row || row.decision !== 'match') {
        results.push({ key, error: 'Match not found' });
        continue;
      }
      const b = row.book;
      const available = await this.availability([this.book(row)], user);
      if (available[0]?.ownedBookId) {
        results.push({ key, bookId: available[0].ownedBookId });
        continue;
      }
      try {
        const result = await this.requests.create(
          { title: b.title, authors: b.authors, isbn13: b.isbn13, providerKey: b.providerKey, providerId: b.providerId, language: 'en' },
          user,
        );
        results.push({ key, request: result.request });
      } catch {
        results.push({ key, error: 'Could not request this book. Check your permissions or retry from Requests.' });
      }
    }
    return { results };
  }
}
