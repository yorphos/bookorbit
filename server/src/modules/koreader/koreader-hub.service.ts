import { createHash } from 'node:crypto';
import { ForbiddenException, Injectable, Logger } from '@nestjs/common';
import { bookRequestWorkKey, Permission } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { PermissionService } from '../../common/services/permission.service';
import { CatalogService } from '../catalog/catalog.service';
import { CollectionService } from '../collection/collection.service';
import { UserPreferencesRepository } from '../user-preferences/user-preferences.repository';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { dedupeDiscovery, type DiscoveryBook } from './koreader-discovery.service';
import { BookRequestService } from '../book-request/book-request.service';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { KoreaderCatalogBooksQueryDto } from './dto/koreader-catalog-query.dto';
import { KoreaderBrowseQueryDto } from './dto/koreader-discovery.dto';
import { KoreaderErrorReportDto, KoreaderWishlistBookDto } from './dto/koreader-hub.dto';
import { DashboardWidgetService } from '../dashboard/dashboard-widget.service';
import { KoreaderDiscoveryService } from './koreader-discovery.service';
import { KoreaderSocialRepository, RECOMMEND_PREFIX, SOCIAL_CATEGORY, type SocialSettings } from './koreader-social.repository';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';

const WISHLIST_PREFIX = 'koreader-wishlist:';
const PAGE_SIZE = 20;
// Broad catalog subjects offered after the library's own genres, so browsing works on an empty library.
const CATALOG_GENRES = [
  'Fiction',
  'Science fiction',
  'Fantasy',
  'Mystery',
  'Thriller',
  'Romance',
  'History',
  'Biography',
  'Horror',
  'Adventure',
  'Classics',
  'Nonfiction',
];

async function optional<T>(load: () => Promise<T>): Promise<T | null> {
  try {
    return await load();
  } catch {
    return null;
  }
}

const DISCOVERY_TTL_MS = 15 * 60 * 1000;
const DISCOVERY_CACHE_MAX = 500;
const READING_DAYS = 371;
const SOCIAL_WINDOW_DAYS = 60;
const SOCIAL_BOOK_LIMIT = 24;
const ERROR_REPORTS_PER_HOUR = 30;

type Candidates = Awaited<ReturnType<KoreaderHubService['discoveryCandidates']>>;

@Injectable()
export class KoreaderHubService {
  private readonly logger = new Logger(KoreaderHubService.name);
  private readonly candidates = new Map<number, { at: number; value: Candidates }>();
  private readonly collecting = new Map<number, Promise<Candidates>>();
  private readonly errorReports = new Map<number, { hour: number; count: number }>();
  constructor(
    private readonly catalog: KoreaderCatalogService,
    private readonly requests: KoreaderRequestsService,
    private readonly permissions: PermissionService,
    private readonly collections: CollectionService,
    private readonly preferences: UserPreferencesRepository,
    private readonly external: KoreaderExternalCatalogService,
    private readonly bookRequests: BookRequestService,
    private readonly catalogGenres: CatalogService,
    private readonly widgets: DashboardWidgetService,
    private readonly discoveryService: KoreaderDiscoveryService,
    private readonly social: KoreaderSocialRepository,
  ) {}

  async home(user: RequestUser) {
    const canRequest = this.permissions.userHas(user, Permission.BookRequestAccess);
    const [dashboard, requests, ready, recent, discovery, streak, goal] = await Promise.all([
      this.catalog.getDashboard(user),
      canRequest ? this.requests.list(1, user).catch(() => null) : Promise.resolve(null),
      canRequest ? this.requests.list(1, user, 'ready').catch(() => null) : Promise.resolve(null),
      this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { page: 1, size: 4, sort: 'recently_added' })),
      this.discovery(user),
      optional(() => this.widgets.getReadingStreak(user)),
      optional(() => this.widgets.getReadingGoal(user)),
    ]);
    return {
      ...discovery,
      generatedAt: dashboard.generatedAt,
      displayName: dashboard.displayName,
      totalBooks: dashboard.totalBooks,
      continueReading: dashboard.continueReading.slice(0, 4),
      recent: recent.items,
      requests: requests?.items.slice(0, 3) ?? [],
      ready: (ready?.items ?? []).filter((r) => r.bookId != null).slice(0, 8),
      requestsUnavailable: canRequest && requests === null,
      streak: streak ? { current: streak.currentStreak, longest: streak.longestStreak } : null,
      goal: goal ? { goal: goal.goalBooks, done: goal.completedBooks, year: goal.year } : null,
    };
  }

  /**
   * Recommendation candidates come from slow public catalog searches, so the last ones are kept for
   * 15 minutes and refreshed in the background. Ownership and request status are never cached:
   * discovery() checks them for this user on every call.
   */
  private async cachedCandidates(user: RequestUser): Promise<Candidates> {
    const cached = this.candidates.get(user.id);
    if (cached && Date.now() - cached.at < DISCOVERY_TTL_MS) return cached.value;
    const fresh = this.refreshCandidates(user);
    if (cached) {
      fresh.catch(() => undefined);
      return cached.value;
    }
    return fresh;
  }

  private refreshCandidates(user: RequestUser) {
    const running = this.collecting.get(user.id);
    if (running) return running;
    const work = this.discoveryCandidates(user)
      .then((value) => {
        this.candidates.delete(user.id);
        if (!value.partial) this.candidates.set(user.id, { at: Date.now(), value });
        while (this.candidates.size > DISCOVERY_CACHE_MAX) this.candidates.delete(this.candidates.keys().next().value!);
        return value;
      })
      .finally(() => this.collecting.delete(user.id));
    this.collecting.set(user.id, work);
    return work;
  }

  /** Reading totals for the Kobo's Stats screen, from the same sources as the web dashboard. */
  async stats(user: RequestUser) {
    const [goal, streak, days, finished, reading] = await Promise.all([
      this.widgets.getReadingGoal(user),
      this.widgets.getReadingStreak(user),
      this.widgets.getReadingDays(user, READING_DAYS),
      this.catalog.getBooksPage(
        user,
        Object.assign(new KoreaderCatalogBooksQueryDto(), { page: 1, size: 10, sort: 'recently_read', readStatus: 'finished' }),
      ),
      this.catalog.getBooksPage(
        user,
        Object.assign(new KoreaderCatalogBooksQueryDto(), { page: 1, size: 1, sort: 'recently_read', readStatus: 'reading' }),
      ),
    ]);
    const minutes = days.minutes;
    const sum = (count: number) => minutes.slice(-count).reduce((total, value) => total + value, 0);
    return {
      goal: { goal: goal.goalBooks, done: goal.completedBooks, year: goal.year },
      streak: { current: streak.currentStreak, longest: streak.longestStreak, lastSevenDays: streak.lastSevenDays },
      minutes: { today: minutes[minutes.length - 1] ?? 0, week: sum(7), month: sum(30), year: sum(365) },
      lastFourteenDays: minutes.slice(-14),
      readingDaysThisYear: minutes.slice(-365).filter((value) => value > 0).length,
      finishedTotal: finished.total,
      readingNow: reading.total,
      recentlyFinished: finished.items,
    };
  }

  /** What to read after finishing a book: the next volume, books ready now and the top matches. */
  async next(user: RequestUser, bookId: number) {
    const canRequest = this.permissions.userHas(user, Permission.BookRequestAccess);
    const book = await this.catalog.getBookDetail(user, bookId);
    const index = book.seriesIndex == null ? null : Number(book.seriesIndex);
    let nextInSeries: unknown = null;
    if (book.seriesName && index != null && Number.isFinite(index)) {
      const owned = (book.seriesMembers ?? [])
        .filter((m) => m.id !== book.id && m.seriesIndex != null && Number(m.seriesIndex) > index)
        .sort((a, b) => Number(a.seriesIndex) - Number(b.seriesIndex))[0];
      if (owned) {
        nextInSeries = { ...owned, bookId: owned.id, authors: book.authors, seriesName: book.seriesName, hasCover: true, updatedAt: book.updatedAt };
      } else if (canRequest) {
        const series = await this.discoveryService
          .series(Object.assign(new KoreaderBrowseQueryDto(), { q: book.seriesName, author: book.authors[0], mode: 'series' }), user)
          .catch(() => null);
        nextInSeries =
          series?.items.find((item) => item.seriesIndex != null && Number(item.seriesIndex) > index && Number(item.seriesIndex) <= index + 1.0001) ??
          series?.items.find((item) => item.seriesIndex != null && Number(item.seriesIndex) > index) ??
          null;
      }
    }
    const ready = canRequest ? ((await this.requests.list(1, user, 'ready').catch(() => null))?.items ?? []) : [];
    return {
      book: {
        id: book.id,
        title: book.title,
        authors: book.authors,
        rating: book.rating,
        readStatus: book.readStatus,
        seriesName: book.seriesName,
        seriesIndex: book.seriesIndex,
      },
      nextInSeries,
      ready: ready.filter((r) => r.bookId != null && r.bookId !== book.id).slice(0, 4),
      canRequest,
    };
  }

  async createCollection(user: RequestUser, name: string) {
    const created = await this.collections.create({ name: name.trim(), icon: 'FolderOpen' }, user);
    return { id: created.id, name: created.name, bookCount: 0 };
  }

  async socialSettings(user: RequestUser): Promise<SocialSettings> {
    const row = await this.preferences.findByCategory(user.id, SOCIAL_CATEGORY);
    return { share: (row?.data as SocialSettings | undefined)?.share === true };
  }

  async setSocialSharing(user: RequestUser, share: boolean) {
    if (share) await this.preferences.upsert(user.id, SOCIAL_CATEGORY, { share: true, since: new Date().toISOString() });
    else await this.preferences.delete(user.id, SOCIAL_CATEGORY);
    return { share };
  }

  /**
   * What other readers on this server are reading, finished or recommended. Both sides opt in:
   * only readers who share appear, and only a reader who shares sees them. A book is listed only
   * when the viewer may open it too.
   */
  async socialFeed(user: RequestUser) {
    const { share } = await this.socialSettings(user);
    if (!share) return { share, people: [], items: [] };
    const people = await this.social.sharers(user.id);
    const ids = people.map((p) => p.userId);
    const since = new Date(Date.now() - SOCIAL_WINDOW_DAYS * 24 * 3600 * 1000);
    const [activity, recommended] = await Promise.all([this.social.activity(ids, since), this.social.recommendations(ids)]);
    const names = new Map(people.map((p) => [p.userId, p.name || p.username]));
    const entries = [
      ...recommended.map((r) => ({ userId: r.userId, bookId: r.bookId, kind: 'recommended' as const, note: r.note, at: r.at })),
      ...activity.map((a) => ({
        userId: a.userId,
        bookId: a.bookId,
        kind: a.status === 'read' ? ('finished' as const) : ('reading' as const),
        note: undefined,
        at: (a.finishedAt ?? a.updatedAt).toISOString(),
      })),
    ].sort((a, b) => b.at.localeCompare(a.at));
    const visible = new Map<number, Awaited<ReturnType<KoreaderCatalogService['getBooksPage']>>['items'][number]>();
    const bookIds = [...new Set(entries.map((e) => e.bookId))].slice(0, 100);
    if (bookIds.length) {
      const page = await this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { ids: bookIds, size: 100 }));
      for (const item of page.items) visible.set(item.id, item);
    }
    const items = entries
      .filter((e) => visible.has(e.bookId))
      .slice(0, SOCIAL_BOOK_LIMIT)
      .map((e) => ({ ...visible.get(e.bookId)!, friend: names.get(e.userId) ?? 'A reader', kind: e.kind, note: e.note ?? null, at: e.at }));
    return { share, people: people.map((p) => p.name || p.username), items };
  }

  async recommend(user: RequestUser, bookId: number, note?: string) {
    await this.catalog.getBookDetail(user, bookId);
    const { share } = await this.socialSettings(user);
    if (!share) throw new ForbiddenException('Turn on sharing with other readers first');
    await this.preferences.upsert(user.id, RECOMMEND_PREFIX + bookId, { bookId, note: note?.trim() || undefined, at: new Date().toISOString() });
    return { recommended: true };
  }

  async unrecommend(user: RequestUser, bookId: number) {
    await this.preferences.delete(user.id, RECOMMEND_PREFIX + bookId);
    return { recommended: false };
  }

  /** An error the plugin hit, sent only when the reader turned error reports on. Logged, never stored. */
  reportError(user: RequestUser, report: KoreaderErrorReportDto) {
    const hour = Math.floor(Date.now() / 3600_000);
    const seen = this.errorReports.get(user.id);
    const count = seen && seen.hour === hour ? seen.count + 1 : 1;
    this.errorReports.set(user.id, { hour, count });
    if (count > ERROR_REPORTS_PER_HOUR) return { accepted: false };
    this.logger.warn(
      `[koreader.plugin_error] [fail] userId=${user.id} version="${sanitizeLogValue(report.version ?? '')}" where="${sanitizeLogValue(report.where ?? '')}" error="${sanitizeLogValue(report.message)}"` +
        (report.trace ? ` trace="${sanitizeLogValue(report.trace.slice(0, 1500))}"` : '') +
        ' - KOReader plugin reported an error',
    );
    return { accepted: true };
  }

  async discoveryCandidates(
    user: RequestUser,
    reading?: Awaited<ReturnType<KoreaderCatalogService['getBooksPage']>>,
    suppliedDetails?: Array<Awaited<ReturnType<KoreaderCatalogService['getBookDetail']>> | null>,
  ) {
    const canRequest = this.permissions.userHas(user, Permission.BookRequestAccess);
    const history =
      reading ??
      (canRequest
        ? await this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { page: 1, size: 3, sort: 'recently_read' }))
        : { items: [] });
    const seeds = history.items.filter((book) => book.lastReadAt).slice(0, 3);
    let partial = suppliedDetails?.some((detail) => detail === null) ?? false;
    const details =
      suppliedDetails ??
      (canRequest
        ? await Promise.all(
            seeds.map((seed) =>
              this.catalog.getBookDetail(user, seed.id).catch(() => {
                partial = true;
                return null;
              }),
            ),
          )
        : []);
    const queries: Array<{ q: string; field: 'author' | 'subject' }> = [];
    const queryKeys = new Set<string>();
    const add = (q: string | undefined, field: 'author' | 'subject') => {
      if (!q?.trim() || queryKeys.has(field + ':' + q.toLowerCase())) return;
      queryKeys.add(field + ':' + q.toLowerCase());
      queries.push({ q, field });
    };
    seeds.forEach((seed, index) => {
      add(seed.authors[0], 'author');
      const genres = details[index]?.genres ?? [];
      add(genres.find((genre) => !/^(fiction|general|novel|novels)$/i.test(genre)) ?? genres[0], 'subject');
    });
    if (!queries.length) add('Fiction', 'subject');
    // Public catalog responses are cached by the existing provider adapter. Never cache
    // ownership or request status: they are checked for this user on every refresh.
    const groups = canRequest
      ? await Promise.all(
          queries.map((query) =>
            this.external
              .search(query.q, query.field, 1, undefined, 'popular', { language: 'en' })
              .then((page) => page.items)
              .catch(() => {
                partial = true;
                return [] as DiscoveryBook[];
              }),
          ),
        )
      : [];
    const seedKeys = new Set(seeds.map((seed) => bookRequestWorkKey(seed.title, seed.authors[0], 'ebook')));
    const candidates: DiscoveryBook[] = [];
    for (let rank = 0; rank < 20; rank++) {
      for (const group of groups) {
        const book = group[rank];
        if (book && !seedKeys.has(bookRequestWorkKey(book.title, book.authors[0], 'ebook'))) candidates.push(book);
      }
    }
    return {
      candidates: dedupeDiscovery(candidates).slice(0, 100),
      partial,
      canRequest,
      recommendationSeeds: seeds.map(({ id, title, authors }) => ({ id, title, authors })),
    };
  }

  async discovery(user: RequestUser) {
    const { candidates: unique, recommendationSeeds: seeds, canRequest, partial: incomplete } = await this.cachedCandidates(user);
    let partial = incomplete;
    let recommended: DiscoveryBook[] = [];
    if (unique.length) {
      try {
        const availability = await this.bookRequests.checkAvailability(
          unique.map((book) => ({
            title: book.title,
            author: book.authors[0],
            isbn13: book.isbn13,
            providerKey: book.providerKey,
            providerId: book.providerId,
            mediaKind: 'ebook' as const,
          })),
          user,
        );
        recommended = unique
          .flatMap((book, index) => {
            const state = availability[index];
            return state && state.ownedBookId == null && state.existingRequestId == null ? [{ ...book, availability: state }] : [];
          })
          .slice(0, 30);
      } catch {
        partial = true;
      }
    }
    return {
      recommendations: recommended,
      partial,
      recommendationSeeds: seeds,
      recommendationReason: !canRequest
        ? 'Book Requests access is required for discovery'
        : partial && !recommended.length
          ? 'Discovery temporarily unavailable'
          : seeds.length
            ? `New books based on your last ${seeds.length} ${seeds.length === 1 ? 'book' : 'books'}`
            : 'Popular books outside your library',
      canRequest,
    };
  }

  /** Genres in books this user can see, most common first, then catalog subjects not already listed. */
  async genres(user: RequestUser) {
    const library = await this.catalogGenres.listGenres(user);
    const seen = new Set(library.map((g) => g.name.trim().toLowerCase()));
    const items = library.map((g) => ({ name: g.name, count: g.count, inLibrary: true }));
    for (const name of CATALOG_GENRES) {
      if (!seen.has(name.toLowerCase())) items.push({ name, count: 0, inLibrary: false });
    }
    return { items };
  }

  async collectionList(user: RequestUser, page: number, bookId?: number) {
    if (bookId) await this.catalog.getBookDetail(user, bookId);
    // Reuse the collection service's owner/membership and visibility rules.
    const all = await this.collections.findAll(user, bookId ? [bookId] : undefined);
    return { items: all.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE), page, hasMore: page * PAGE_SIZE < all.length };
  }

  async addToCollection(user: RequestUser, id: number, bookId: number) {
    await this.catalog.getBookDetail(user, bookId);
    return this.collections.addBooks(id, { bookIds: [bookId] }, user);
  }

  async removeFromCollection(user: RequestUser, id: number, bookId: number) {
    return this.collections.removeBooks(id, { bookIds: [bookId] }, user);
  }

  async wishlist(user: RequestUser, page: number) {
    const rows = await this.preferences.findByCategoryPrefix(user.id, WISHLIST_PREFIX, PAGE_SIZE + 1, (page - 1) * PAGE_SIZE);
    const items = rows
      .slice(0, PAGE_SIZE)
      .map((row) => ({ ...(row.data as unknown as KoreaderWishlistBookDto), wishlistKey: row.category.slice(WISHLIST_PREFIX.length) }));
    if (!this.permissions.userHas(user, Permission.BookRequestAccess) || !items.length) return { items, page, hasMore: rows.length > PAGE_SIZE };
    const available = await this.bookRequests.checkAvailability(
      items.map((book) => ({
        title: book.title,
        author: book.authors?.[0],
        isbn13: book.isbn13,
        providerKey: book.providerKey,
        providerId: book.providerId,
        mediaKind: 'ebook' as const,
      })),
      user,
    );
    return { items: items.map((book, index) => ({ ...book, availability: available[index] })), page, hasMore: rows.length > PAGE_SIZE };
  }

  async saveWishlist(user: RequestUser, book: KoreaderWishlistBookDto) {
    const key = createHash('sha256')
      .update(bookRequestWorkKey(book.title, book.authors?.[0], 'ebook'))
      .digest('hex')
      .slice(0, 32);
    // One unique row per user and work avoids lost additions from concurrent devices.
    await this.preferences.upsert(user.id, WISHLIST_PREFIX + key, { ...book });
    return { key };
  }

  async removeWishlist(user: RequestUser, key: string) {
    await this.preferences.delete(user.id, WISHLIST_PREFIX + key);
    return { removed: true };
  }
}
