import { createHash } from 'node:crypto';
import { Injectable } from '@nestjs/common';
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
import { KoreaderWishlistBookDto } from './dto/koreader-hub.dto';

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

@Injectable()
export class KoreaderHubService {
  constructor(
    private readonly catalog: KoreaderCatalogService,
    private readonly requests: KoreaderRequestsService,
    private readonly permissions: PermissionService,
    private readonly collections: CollectionService,
    private readonly preferences: UserPreferencesRepository,
    private readonly external: KoreaderExternalCatalogService,
    private readonly bookRequests: BookRequestService,
    private readonly catalogGenres: CatalogService,
  ) {}

  async home(user: RequestUser) {
    const canRequest = this.permissions.userHas(user, Permission.BookRequestAccess);
    const [dashboard, requests, recent, discovery] = await Promise.all([
      this.catalog.getDashboard(user),
      canRequest ? this.requests.list(1, user).catch(() => null) : Promise.resolve(null),
      this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { page: 1, size: 4, sort: 'recently_added' })),
      this.discovery(user),
    ]);
    return {
      ...discovery,
      generatedAt: dashboard.generatedAt,
      displayName: dashboard.displayName,
      totalBooks: dashboard.totalBooks,
      continueReading: dashboard.continueReading.slice(0, 4),
      recent: recent.items,
      requests: requests?.items.slice(0, 3) ?? [],
      requestsUnavailable: canRequest && requests === null,
    };
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
    const { candidates: unique, recommendationSeeds: seeds, canRequest, partial: incomplete } = await this.discoveryCandidates(user);
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
