import { BadGatewayException, BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { ProviderConfigService } from '../metadata-preferences/provider-config.service';
import { fetchWithThrottle } from '../metadata-fetch/fetch-with-throttle';
import { mapOpenLibraryDoc, mapOpenLibraryWork } from '../metadata-fetch/providers/open-library/open-library.mapper';
import type { OpenLibraryDoc, OpenLibraryWork } from '../metadata-fetch/providers/open-library/open-library.types';
import type { DiscoveryBook } from './koreader-discovery.service';

interface SearchPage {
  docs: OpenLibraryDoc[];
  numFound: number;
}
interface Edition {
  title: string;
  physical_format?: string;
  publishers?: string[];
  publish_date?: string;
  isbn_13?: string[];
  languages?: Array<{ key: string }>;
  series?: string[];
}
interface Editions {
  entries: Edition[];
  size: number;
}
const PAGE_SIZE = 20;
const MAX_CACHE_ENTRIES = 200;
const TTL = 15 * 60 * 1000;
const quote = (value: string) => '"' + value.replace(/[\\"]/g, ' ').trim() + '"';

@Injectable()
export class KoreaderExternalCatalogService {
  // Only public provider metadata lives here. Ownership, permissions and requests are never cached.
  private readonly cache = new Map<string, { expires: number; value: unknown; bytes: number }>();
  private cachedBytes = 0;
  private readonly pending = new Map<string, Promise<unknown>>();
  constructor(private readonly config: ProviderConfigService) {}

  async json<T>(path: string): Promise<T> {
    if (!(await this.config.getConfig()).openLibrary.enabled) throw new NotFoundException('Open Library is disabled');
    const cached = this.cache.get(path);
    if (cached && cached.expires > Date.now()) return cached.value as T;
    const pending = this.pending.get(path);
    if (pending) return pending as Promise<T>;
    if (this.pending.size >= 16) throw new BadGatewayException('Catalog busy; try again');
    const promise = (async () => {
      const response = await fetchWithThrottle('https://openlibrary.org' + path, { signal: AbortSignal.timeout(12000), redirect: 'error' });
      if (!response.ok) throw new BadGatewayException('Catalog temporarily unavailable');
      if (!response.body) throw new BadGatewayException('Catalog unavailable');
      const chunks: Uint8Array[] = [];
      let bytes = 0;
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > 2_000_000) throw new BadGatewayException('Catalog response too large');
        chunks.push(chunk);
      }
      const text = Buffer.concat(chunks).toString('utf8');
      const value: unknown = JSON.parse(text);
      this.cachedBytes -= this.cache.get(path)?.bytes ?? 0;
      this.cache.delete(path);
      while (this.cache.size && (this.cache.size >= MAX_CACHE_ENTRIES || this.cachedBytes + bytes > 8_000_000)) {
        const oldest = this.cache.keys().next().value!;
        this.cachedBytes -= this.cache.get(oldest)!.bytes;
        this.cache.delete(oldest);
      }
      this.cache.set(path, { expires: Date.now() + TTL, value, bytes });
      this.cachedBytes += bytes;
      return value;
    })();
    this.pending.set(path, promise);
    try {
      return (await promise) as T;
    } finally {
      this.pending.delete(path);
    }
  }

  async search(
    q: string,
    field: string,
    page: number,
    author?: string,
    sort = 'popular',
    filters: { language?: string; refine?: string; genre?: string } = {},
  ) {
    const params = new URLSearchParams({
      limit: String(PAGE_SIZE),
      page: String(page),
      fields: 'key,title,author_name,first_publish_year,isbn,cover_i,language,subject,series,ratings_average,ratings_count,number_of_pages_median',
    });
    if (field === 'subject') {
      params.set('q', 'subject:' + quote(q));
      params.set('sort', sort === 'new' ? 'new' : 'readinglog');
    } else if (field === 'series') params.set('q', 'series:' + quote(q) + (author ? ' AND author:' + quote(author) : ''));
    else params.set(field === 'all' ? 'q' : field === 'isbn' ? 'isbn' : field === 'author' ? 'author' : 'title', q);
    const clauses: string[] = [];
    if (filters.language) {
      const codes: Record<string, string> = { en: 'eng', fr: 'fre', es: 'spa', de: 'ger', it: 'ita', pt: 'por' };
      if (codes[filters.language]) clauses.push('language:' + codes[filters.language]);
    }
    if (filters.refine) clauses.push('title:' + quote(filters.refine));
    if (filters.genre) clauses.push('subject:' + quote(filters.genre));
    if (clauses.length) params.set('q', [params.get('q'), ...clauses].filter(Boolean).join(' AND '));
    if (sort === 'new') params.set('sort', 'new');
    const data = await this.json<SearchPage>('/search.json?' + params.toString());
    const items: DiscoveryBook[] = (data.docs ?? []).map((doc) => {
      const c = mapOpenLibraryDoc(doc);
      return {
        title: c.title ?? doc.title,
        authors: c.authors ?? [],
        isbn10: c.isbn10,
        isbn13: c.isbn13,
        language: c.language,
        providerKey: 'openLibrary',
        providerId: c.providerId,
        coverUrl: c.coverUrl,
        genres: c.genres,
        publishedYear: c.publishedYear,
        pageCount: c.pageCount,
        communityRating: c.communityRating,
        communityRatingCount: c.communityRatingCount,
        ...(field === 'series' ? { seriesName: q } : {}),
      };
    });
    return { items, total: data.numFound ?? 0, page, hasMore: page * PAGE_SIZE < (data.numFound ?? 0) };
  }

  async synopsis(id: string) {
    const work = await this.json<OpenLibraryWork>('/works/' + id + '.json');
    return mapOpenLibraryWork(work).description?.slice(0, 12000);
  }

  async detail(id: string, page: number) {
    const [work, editions] = await Promise.all([
      this.json<OpenLibraryWork>('/works/' + id + '.json'),
      this.json<Editions>('/works/' + id + '/editions.json?limit=20&offset=' + (page - 1) * 20),
    ]);
    const c = mapOpenLibraryWork(work);
    return {
      description: c.description?.slice(0, 12000),
      genres: c.genres?.slice(0, 12),
      coverId: work.covers?.find((id) => id > 0),
      editions: (editions.entries ?? []).map((e) => ({
        title: e.title,
        format: e.physical_format,
        publisher: e.publishers?.[0],
        date: e.publish_date,
        isbn13: e.isbn_13?.[0],
        languages: e.languages?.map((l) => l.key.split('/').pop()),
        series: e.series,
      })),
      page,
      hasMore: page * 20 < editions.size,
    };
  }

  async cover(id: string) {
    const work = await this.json<OpenLibraryWork>('/works/' + id + '.json');
    const coverId = work.covers?.find((id) => Number.isSafeInteger(id) && id > 0);
    if (!coverId) throw new NotFoundException('No cover');
    return this.coverUrl(`https://covers.openlibrary.org/b/id/${coverId}-M.jpg`);
  }

  async coverUrl(address: string) {
    let url = new URL(address);
    const allowed = ['covers.openlibrary.org', 'images-na.ssl-images-amazon.com', 'm.media-amazon.com', 'images.gr-assets.com', 'i.gr-assets.com'];
    const fromOpenLibrary = url.hostname === 'covers.openlibrary.org';
    let response: Response | undefined;
    const signal = AbortSignal.timeout(12000);
    for (let hop = 0; hop <= 3; hop++) {
      const archiveCover = fromOpenLibrary && (url.hostname === 'archive.org' || /^ia[0-9]+\.(us|eu)\.archive\.org$/.test(url.hostname));
      if (url.protocol !== 'https:' || url.port || url.username || url.password || (!allowed.includes(url.hostname) && !archiveCover))
        throw new BadRequestException('Unsupported cover host');
      try {
        response = await fetchWithThrottle(url.toString(), { signal, redirect: 'manual' });
      } catch {
        throw new BadGatewayException('Cover unavailable');
      }
      if (response.status < 300 || response.status >= 400) break;
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location || hop === 3) throw new BadGatewayException('Cover redirect unavailable');
      url = new URL(location, url);
    }
    if (!response) throw new BadGatewayException('Cover unavailable');
    if (!response.ok || !response.headers.get('content-type')?.startsWith('image/')) throw new BadGatewayException('Cover unavailable');
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    if (!response.body) throw new BadGatewayException('Cover unavailable');
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > 2_000_000) {
        throw new BadGatewayException('Cover too large');
      }
      chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  }
}
