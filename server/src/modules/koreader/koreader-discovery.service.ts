import { KoreaderCoverCacheService } from './koreader-cover-cache.service';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { BookRequestService } from '../book-request/book-request.service';
import { KoreaderCatalogBooksQueryDto } from './dto/koreader-catalog-query.dto';
import { KoreaderBrowseQueryDto, KoreaderBulkRequestsDto } from './dto/koreader-discovery.dto';
import { Injectable, ForbiddenException, HttpException } from '@nestjs/common';
import { Permission, bookRequestWorkKey } from '@bookorbit/types';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { KoreaderDiscoveryQueryDto } from './dto/koreader-discovery.dto';

export interface DiscoveryBook {
  title: string;
  authors: string[];
  isbn10?: string | null;
  isbn13?: string | null;
  language?: string | null;
  providerKey?: string;
  providerId?: string;
  description?: string;
  coverUrl?: string;
  seriesName?: string | null;
  seriesIndex?: string | number | null;
  genres?: string[];
  publishedYear?: number;
  pageCount?: number;
  communityRating?: number;
  communityRatingCount?: number;
  bookId?: number;
  readStatus?: string | null;
  formats?: string[];
  availability?: { ownedBookId: number | null; existingRequestId: number | null; existingRequestStatus: string | null; alreadySubscribed: boolean };
  editions?: Array<{ providerKey: string; providerId: string; language?: string | null; isbn13?: string | null }>;
}

export function dedupeDiscovery(items: DiscoveryBook[]): DiscoveryBook[] {
  const result: DiscoveryBook[] = [];
  const aliases = new Map<string, DiscoveryBook>();
  for (const item of items) {
    const keys = [bookRequestWorkKey(item.title, item.authors[0], 'ebook')];
    if (item.isbn13) keys.push(`isbn:${item.isbn13.replace(/[^0-9X]/gi, '')}`);
    const previous = keys.map((key) => aliases.get(key)).find(Boolean);
    if (previous) {
      if (
        item.providerKey &&
        item.providerId &&
        !previous.editions?.some((e) => e.providerKey === item.providerKey && e.providerId === item.providerId)
      ) {
        (previous.editions ??= []).push({ providerKey: item.providerKey, providerId: item.providerId, language: item.language, isbn13: item.isbn13 });
      }
      previous.description ||= item.description;
      previous.coverUrl ||= item.coverUrl;
      previous.seriesName ||= item.seriesName;
      previous.seriesIndex ??= item.seriesIndex;
      for (const key of keys) aliases.set(key, previous);
    } else {
      const entry = {
        ...item,
        editions:
          item.providerKey && item.providerId
            ? [{ providerKey: item.providerKey, providerId: item.providerId, language: item.language, isbn13: item.isbn13 }]
            : [],
      };
      result.push(entry);
      for (const key of keys) aliases.set(key, entry);
    }
  }
  return result;
}

@Injectable()
export class KoreaderDiscoveryService {
  constructor(
    private readonly catalog: KoreaderCatalogService,
    private readonly requests: KoreaderRequestsService,
    private readonly permissions: PermissionService,
    private readonly external: KoreaderExternalCatalogService,
    private readonly bookRequests: BookRequestService,
    private readonly covers: KoreaderCoverCacheService,
  ) {}

  requireAccess(user: RequestUser) {
    if (!this.permissions.userHas(user, Permission.BookRequestAccess)) throw new ForbiddenException('Book requests access required');
  }

  async search(query: KoreaderDiscoveryQueryDto, user: RequestUser) {
    this.requireAccess(user);
    const [library, metadata, publicPage] = await Promise.all([
      this.catalog.getBooksPage(
        user,
        Object.assign(new KoreaderCatalogBooksQueryDto(), {
          page: query.page,
          size: 20,
          sort: query.sort === 'new' ? 'recently_added' : query.field === 'series' ? 'series' : 'title',
          genre: query.genre,
          language: query.language,
          ...(query.field === 'series' ? { series: query.q } : query.field === 'author' ? { author: query.q } : { q: query.q }),
        }),
      ),
      (query.page === 1 && query.scope !== 'library' && !query.language && !query.genre && query.sort !== 'new'
        ? this.requests.search({ q: query.q, field: query.field === 'all' ? 'title' : query.field }, user, false)
        : Promise.resolve({ items: [], partial: false, noProviders: false, limited: false })
      ).catch(() => ({ items: [], partial: true, noProviders: false, limited: false })),
      query.scope === 'library'
        ? Promise.resolve({ items: [] as DiscoveryBook[], total: 0, hasMore: false })
        : this.external
            .search(query.q, query.field, query.page, undefined, query.sort, query)
            .catch(() => ({ items: [] as DiscoveryBook[], total: 0, hasMore: false, unavailable: true })),
    ]);
    const external = { ...metadata, items: [...publicPage.items, ...(query.page === 1 ? metadata.items : [])] };
    const owned: DiscoveryBook[] = library.items.map((book) => ({
      ...book,
      title: book.title,
      authors: book.authors,
      bookId: book.id,
      readStatus: book.readStatus,
      seriesName: book.seriesName,
      seriesIndex: book.seriesIndex,
      coverUrl: book.thumbnailUrl ?? undefined,
      formats: book.formats,
      availability: { ownedBookId: book.id, existingRequestId: null, existingRequestStatus: null, alreadySubscribed: false },
    }));
    external.items = await this.availability(external.items, user);
    const missing = dedupeDiscovery(external.items).filter((item) => !item.availability?.ownedBookId || library.total === 0);
    const items = dedupeDiscovery([...owned, ...missing]);
    return {
      items: query.scope === 'requestable' ? items.filter((item) => !item.availability?.ownedBookId && !item.availability?.existingRequestId) : items,
      page: query.page,
      pageSize: 40,
      hasMore: (query.scope !== 'requestable' && query.page * 20 < library.total) || publicPage.hasMore,
      libraryTotal: library.total,
      externalTotal: publicPage.total,
      partial: external.partial || 'unavailable' in publicPage,
      limited: external.limited,
    };
  }
  private async availability(items: DiscoveryBook[], user: RequestUser): Promise<DiscoveryBook[]> {
    if (!items.length) return [];
    const found = await this.bookRequests.checkAvailability(
      items.map((b) => ({
        title: b.title,
        author: b.authors[0],
        isbn13: b.isbn13 ?? undefined,
        providerKey: b.providerKey,
        providerId: b.providerId,
        mediaKind: 'ebook' as const,
      })),
      user,
    );
    return items.map((book, index) => ({
      ...book,
      availability: { ...found[index], ownedBookId: book.bookId ?? found[index]?.ownedBookId ?? null },
    }));
  }

  async browse(query: KoreaderBrowseQueryDto, user: RequestUser) {
    this.requireAccess(user);
    if (query.scope === 'library') {
      const page = await this.catalog.getBooksPage(
        user,
        Object.assign(new KoreaderCatalogBooksQueryDto(), {
          page: query.page,
          size: 20,
          sort: query.sort === 'new' ? 'recently_added' : 'title',
          genre: query.mode === 'subject' ? query.q : query.genre,
          author: query.mode === 'author' ? query.q : undefined,
          series: query.mode === 'series' ? query.q : undefined,
          q: query.refine,
          language: query.language,
        }),
      );
      return { ...page, items: page.items.map((b) => ({ ...b, bookId: b.id })), hasMore: query.page * 20 < page.total };
    }
    const page = await this.external.search(query.q, query.mode, query.page, query.author, query.sort, query);
    const items = await this.availability(dedupeDiscovery(page.items), user);
    return {
      ...page,
      total: undefined,
      items: query.scope === 'requestable' ? items.filter((b) => !b.availability?.ownedBookId && !b.availability?.existingRequestId) : items,
    };
  }

  async work(id: string, page: number, user: RequestUser) {
    this.requireAccess(user);
    return this.external.detail(id, page);
  }
  async cover(id: string, user: RequestUser) {
    this.requireAccess(user);
    return this.covers.get('work:' + id, () => this.external.cover(id));
  }

  async coverUrl(address: string, user: RequestUser) {
    this.requireAccess(user);
    return this.covers.get(address, () => this.external.coverUrl(address));
  }

  async series(query: KoreaderBrowseQueryDto, user: RequestUser) {
    this.requireAccess(user);
    const metadataPending = Promise.all([
      this.catalog.getBooksPage(user, Object.assign(new KoreaderCatalogBooksQueryDto(), { series: query.q, size: 100, sort: 'series' })),
      this.requests.search({ q: query.q + (query.author ? ' ' + query.author : ''), field: 'series' }, user, false).catch(() => ({ items: [] })),
    ]);
    void metadataPending.catch(() => undefined);
    const external: DiscoveryBook[] = [];
    const deadline = Date.now() + 22000;
    let partial = false;
    let truncated = false;
    // Explicitly bounded. Never pretend a 100-volume snapshot is an exhaustive bibliography.
    for (let page = 1; page <= 5; page++) {
      if (Date.now() > deadline) {
        partial = true;
        break;
      }
      try {
        const result = await this.external.search(query.q, 'series', page, query.author);
        external.push(...result.items);
        if (!result.hasMore) break;
        if (page === 5) truncated = true;
      } catch {
        partial = true;
        break;
      }
    }
    const [library, metadata] = await metadataPending;
    truncated ||= library.total > 100;
    const matching = metadata.items.filter((item) => item.seriesName?.toLocaleLowerCase() === query.q.toLocaleLowerCase());
    const owned: DiscoveryBook[] = library.items.map((book) => ({
      ...book,
      bookId: book.id,
      availability: { ownedBookId: book.id, existingRequestId: null, existingRequestStatus: null, alreadySubscribed: false },
    }));
    const combined = dedupeDiscovery([...owned, ...matching, ...external]);
    const items: DiscoveryBook[] = [];
    if (combined.length > 100) truncated = true;
    for (let index = 0; index < combined.length; index += 50) items.push(...(await this.availability(combined.slice(index, index + 50), user)));
    const ownedIds = [...new Set(items.map((b) => b.availability?.ownedBookId).filter((id): id is number => id != null))];
    for (let offset = 0; offset < ownedIds.length; offset += 100) {
      const progress = await this.catalog.getBooksPage(
        user,
        Object.assign(new KoreaderCatalogBooksQueryDto(), { ids: ownedIds.slice(offset, offset + 100), size: 100 }),
      );
      for (const book of progress.items) {
        for (const item of items)
          if (item.availability?.ownedBookId === book.id) {
            item.readStatus = book.readStatus;
            item.bookId = book.id;
            Object.assign(item, {
              progressPercentage: book.progressPercentage,
              hasCover: book.hasCover,
              thumbnailUrl: book.thumbnailUrl,
              updatedAt: book.updatedAt,
            });
          }
      }
    }
    for (const item of items) {
      const index = Number(item.seriesIndex);
      item.seriesIndex = item.seriesIndex != null && Number.isFinite(index) && index >= 0 ? index : null;
    }
    items.sort((a, b) => Number(a.seriesIndex ?? Infinity) - Number(b.seriesIndex ?? Infinity) || a.title.localeCompare(b.title));
    const numbered = items.filter((b) => b.seriesIndex != null);
    const next = numbered.find((b) => b.readStatus === 'reading') ?? numbered.find((b) => b.readStatus !== 'read' && b.readStatus !== 'finished');
    const indices = new Set(numbered.map((book) => Number(book.seriesIndex)));
    const gaps: number[] = [];
    const last = Math.min(1000, Math.max(0, ...indices));
    for (let index = 1; index < last && gaps.length < 20; index++) if (!indices.has(index)) gaps.push(index);
    return {
      items,
      partial,
      truncated,
      gaps,
      orderingComplete: numbered.length === items.length && items.length > 0 && gaps.length === 0,
      next: next ?? null,
    };
  }

  async requestMany(dto: KoreaderBulkRequestsDto, user: RequestUser) {
    this.requireAccess(user);
    const results: Array<{
      title: string;
      error?: number;
      request?: Awaited<ReturnType<KoreaderRequestsService['create']>>['request'];
      subscribed?: boolean;
    }> = [];
    for (const book of dto.books) {
      try {
        results.push({ title: book.title, ...(await this.requests.create(book, user)) });
      } catch (error) {
        results.push({ title: book.title, error: error instanceof HttpException ? error.getStatus() : 503 });
      }
    }
    return { results };
  }
}
