import { Test } from '@nestjs/testing';
import { ValidationPipe } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { PermissionService } from '../../common/services/permission.service';
import { makeUser } from '../../common/test-utils/make-user';
import { BookRequestService } from '../book-request/book-request.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { KoreaderDiscoveryService, dedupeDiscovery } from './koreader-discovery.service';
import { KoreaderCoverCacheService } from './koreader-cover-cache.service';
import { KoreaderBulkRequestsDto, KoreaderWorkParamsDto } from './dto/koreader-discovery.dto';
const user = makeUser({ id: 7, permissions: [Permission.KoreaderSync, Permission.BookRequestAccess] });
const book = { title: 'A Christmas Carol', authors: ['Charles Dickens'], providerKey: 'openLibrary', providerId: 'OL1W' };
const missing = { ownedBookId: null, existingRequestId: null, existingRequestStatus: null, alreadySubscribed: false };
describe('device discovery', () => {
  const catalog = { getBooksPage: vi.fn() };
  const requests = { search: vi.fn(), create: vi.fn() };
  const external = { search: vi.fn(), detail: vi.fn(), cover: vi.fn() };
  const core = { checkAvailability: vi.fn() };
  let service: KoreaderDiscoveryService;
  beforeEach(async () => {
    vi.resetAllMocks();
    const module = await Test.createTestingModule({
      providers: [
        KoreaderDiscoveryService,
        PermissionService,
        { provide: KoreaderCatalogService, useValue: catalog },
        { provide: KoreaderRequestsService, useValue: requests },
        { provide: KoreaderExternalCatalogService, useValue: external },
        { provide: BookRequestService, useValue: core },
        { provide: KoreaderCoverCacheService, useValue: { get: (_key: string, fetch: () => Promise<Buffer>) => fetch() } },
      ],
    }).compile();
    service = module.get(KoreaderDiscoveryService);
    catalog.getBooksPage.mockResolvedValue({ items: [], total: 0 });
    requests.search.mockResolvedValue({ items: [], partial: false });
    external.search.mockResolvedValue({ items: [book], total: 1, hasMore: false });
    core.checkAvailability.mockImplementation((items) => Promise.resolve(items.map(() => missing)));
  });
  it('filters library genre browsing before pagination and skips external providers', async () => {
    catalog.getBooksPage.mockResolvedValue({ items: [{ id: 8, ...book }], total: 1, hasMore: false });
    const result = await service.browse(
      { q: 'Gothic', mode: 'subject', scope: 'library', language: 'en', refine: 'Carol', sort: 'new', page: 1 },
      user,
    );
    expect(catalog.getBooksPage).toHaveBeenCalledWith(
      user,
      expect.objectContaining({ genre: 'Gothic', language: 'en', q: 'Carol', sort: 'recently_added' }),
    );
    expect(external.search).not.toHaveBeenCalled();
    expect(result.items[0].bookId).toBe(8);
  });
  it('deduplicates providers and retains edition metadata', () => {
    const rows = dedupeDiscovery([book, { ...book, providerKey: 'goodreads', providerId: '123', language: 'en', description: 'A ghost story' }]);
    expect(rows).toHaveLength(1);
    expect(rows[0].editions).toHaveLength(2);
    expect(rows[0].description).toBe('A ghost story');
  });
  it('combines owned books and missing works with fresh request availability', async () => {
    catalog.getBooksPage.mockResolvedValue({ items: [{ id: 8, title: 'Another book', authors: ['An Author'], formats: ['epub'] }], total: 1 });
    const first = await service.search({ q: 'Carol', field: 'title', page: 1 }, user);
    expect(first.items).toHaveLength(2);
    expect(first.items[0].availability?.ownedBookId).toBe(8);
    core.checkAvailability.mockResolvedValue([{ ...missing, existingRequestId: 3, existingRequestStatus: 'downloading', alreadySubscribed: true }]);
    const second = await service.search({ q: 'Carol', field: 'title', page: 1 }, user);
    expect(second.items[1].availability?.existingRequestStatus).toBe('downloading');
    expect(core.checkAvailability).toHaveBeenLastCalledWith(expect.any(Array), user);
  });
  it('keeps the library usable when external sources fail', async () => {
    external.search.mockRejectedValue(new Error('offline'));
    requests.search.mockRejectedValue(new Error('offline'));
    catalog.getBooksPage.mockResolvedValue({ items: [{ id: 8, ...book }], total: 1 });
    const result = await service.search({ q: 'Carol', field: 'title', page: 1 }, user);
    expect(result.items[0].bookId).toBe(8);
    expect(result.partial).toBe(true);
  });
  it('keeps In Library independent of external services', async () => {
    catalog.getBooksPage.mockResolvedValue({
      items: [{ id: 8, title: 'Alice', authors: ['Lewis Carroll'], hasCover: true, progressPercentage: 42 }],
      total: 1,
    });
    const result = await service.search({ q: 'Alice', field: 'all', scope: 'library', page: 1 }, user);
    expect(result.items[0]).toMatchObject({ bookId: 8, hasCover: true, progressPercentage: 42 });
    expect(external.search).not.toHaveBeenCalled();
    expect(requests.search).not.toHaveBeenCalled();
  });
  it('excludes already owned and requested books from Requestable while preserving further catalog pages', async () => {
    external.search.mockResolvedValue({ items: [book, { ...book, title: 'Owned' }, { ...book, title: 'Pending' }], hasMore: true });
    core.checkAvailability.mockResolvedValue([missing, { ...missing, ownedBookId: 8 }, { ...missing, existingRequestId: 9 }]);
    const result = await service.search({ q: 'Carol', field: 'all', scope: 'requestable', page: 1 }, user);
    expect(result.items.map((item) => item.title)).toEqual([book.title]);
    expect(result.hasMore).toBe(true);
  });
  it('requires request access before every external call or mutation', async () => {
    const denied = makeUser({ permissions: [Permission.KoreaderSync] });
    await expect(service.browse({ q: 'Fantasy', field: 'title', mode: 'subject', page: 1 }, denied)).rejects.toThrow();
    await expect(service.cover('OL1W', denied)).rejects.toThrow();
    await expect(service.requestMany({ books: [book] }, denied)).rejects.toThrow();
    expect(external.search).not.toHaveBeenCalled();
    expect(requests.create).not.toHaveBeenCalled();
  });
  it('orders confirmed series numbers and preserves gaps as unknown ordering', async () => {
    catalog.getBooksPage.mockResolvedValue({
      items: [
        { id: 2, title: 'Second', authors: ['Writer'], seriesIndex: '2', readStatus: 'unread' },
        { id: 1, title: 'First', authors: ['Writer'], seriesIndex: '1', readStatus: 'read' },
      ],
      total: 2,
    });
    external.search.mockResolvedValue({ items: [{ title: 'Unnumbered', authors: ['Writer'] }], hasMore: false });
    const result = await service.series({ q: 'Series', mode: 'series', field: 'title', page: 1 }, user);
    expect(result.items.map((b) => b.title)).toEqual(['First', 'Second', 'Unnumbered']);
    expect(result.orderingComplete).toBe(false);
    expect(result.next?.title).toBe('Second');
  });
  it('bounds series enumeration and exposes truncation', async () => {
    external.search.mockResolvedValue({ items: [book], hasMore: true });
    const result = await service.series({ q: 'Series', mode: 'series', field: 'title', page: 1 }, user);
    expect(external.search).toHaveBeenCalledTimes(5);
    expect(result.truncated).toBe(true);
  });
  it('keeps normal approval and reports partial batch outcomes without retrying writes', async () => {
    requests.create
      .mockResolvedValueOnce({ request: { id: 9, status: 'pending' }, subscribed: false })
      .mockRejectedValueOnce(new Error('private upstream secret'));
    const result = await service.requestMany({ books: [book, { ...book, title: 'Another' }] }, user);
    expect(result.results[0].request?.status).toBe('pending');
    expect(result.results[1]).toEqual({ title: 'Another', error: 503 });
    expect(requests.create).toHaveBeenCalledTimes(2);
  });
  it('rejects injected acquisition fields and unsafe work identifiers', async () => {
    const pipe = new ValidationPipe({ transform: true, whitelist: true, forbidNonWhitelisted: true });
    await expect(
      pipe.transform({ books: [{ ...book, downloadUrl: 'http://localhost/private' }] }, { type: 'body', metatype: KoreaderBulkRequestsDto }),
    ).rejects.toThrow();
    await expect(pipe.transform({ id: '../secret' }, { type: 'param', metatype: KoreaderWorkParamsDto })).rejects.toThrow();
  });
});
