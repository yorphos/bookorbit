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
import type { RouletteDecisionDto, RouletteQueryDto, RouletteTasteDto } from './dto/koreader-roulette.dto';
import type { RouletteRecord } from './koreader-roulette.repository';
@Injectable()
export class KoreaderRouletteService {
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
  async queue(user: RequestUser) {
    this.access(user);
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
    const discovery = await this.hub.discoveryCandidates(user, history, details);
    let partial = discovery.partial;
    const queries: Array<{ q: string; field: string }> = [];
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
              if (q.field === 'title' && p.items[0]) signals.push({ book: p.items[0], weight: 1.8 });
              return p.items;
            })
            .catch(() => {
              partial = true;
              return [];
            }),
      ),
    );
    const candidates = dedupeDiscovery([...discovery.candidates, ...pools.flat()])
      .filter((book) => book.title.length <= 500 && (book.authors[0]?.length ?? 0) <= 255)
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
    const ranked = rankRoulette(missing, signals, 'hybrid', 5);
    // The Kobo displays one card per call. Advance exploration across decisions,
    // rather than leaving exploratory cards permanently behind the first result.
    if (records.filter((r) => ['match', 'pass', 'skip'].includes(r.decision)).length % 5 === 4 && ranked[4]) ranked.unshift(ranked.splice(4, 1)[0]);
    // Fetch full prose only for the displayed card; the public work adapter caches it.
    const first = ranked[0];
    if (first?.providerKey === 'openLibrary' && first.providerId) {
      try {
        first.description = (await this.external.synopsis(first.providerId)) ?? first.description;
      } catch {
        partial = true;
      }
    }
    return {
      items: ranked.slice(0, 1).map((book) => ({ ...book, rouletteKey: rouletteKey(book) })),
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
  decide(user: RequestUser, input: RouletteDecisionDto) {
    this.access(user);
    return this.repository.decide(user.id, input);
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
    return input ? this.repository.tastes(user.id, input) : ((await this.repository.get(user.id, 'tastes')) ?? { genres: [], favorites: [] });
  }
  reset(user: RequestUser) {
    this.access(user);
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
