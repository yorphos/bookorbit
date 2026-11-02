import { KoreaderCatalogService } from './koreader-catalog.service';
import { RequestAutomationService } from '../book-request/fulfillment/request-automation.service';
import { Test } from '@nestjs/testing';
import { ValidationPipe } from '@nestjs/common';
import { GUARDS_METADATA } from '@nestjs/common/constants';
import { Permission } from '@bookorbit/types';
import { of } from 'rxjs';
import { PermissionService } from '../../common/services/permission.service';
import { makeUser } from '../../common/test-utils/make-user';
import { RequestVerificationService } from '../book-request/fulfillment/request-verification.service';
import { RequestFulfillmentService } from '../book-request/fulfillment/request-fulfillment.service';
import { BookRequestService } from '../book-request/book-request.service';
import { MetadataFetchService } from '../metadata-fetch/metadata-fetch.service';
import { ProviderRegistry } from '../metadata-fetch/provider-registry';
import { ProviderConfigService } from '../metadata-preferences/provider-config.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { KoreaderRequestsController } from './koreader-requests.controller';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderCreateRequestDto, KoreaderRequestPageDto, KoreaderRequestSearchDto } from './dto/koreader-requests.dto';

const user = makeUser({ id: 7, permissions: [Permission.KoreaderSync, Permission.BookRequestAccess] });
const item = {
  id: 12,
  userId: 7,
  title: 'A Christmas Carol',
  authors: ['Charles Dickens'],
  status: 'pending',
  matchedBookId: null,
  subscribers: [],
  updatedAt: '2026-11-02T01:00:00Z',
  download: { status: 'downloading', progressPercent: 25, errorMessage: 'private provider token', releaseTitle: 'private release' },
};

describe('KOReader book requests', () => {
  const requests = {
    cancel: vi.fn(),
    submit: vi.fn(),
    requestReplacement: vi.fn(),
    requestBookReplacement: vi.fn(),
    listMine: vi.fn(),
    getOne: vi.fn(),
    checkAvailability: vi.fn(),
    assertCanFulfil: vi.fn(),
  };
  const fulfillment = { listReleases: vi.fn(), findTriedReleaseKeys: vi.fn(), grab: vi.fn() };
  const catalog = { getBookDetail: vi.fn() };
  const verification = { discardHeldImport: vi.fn() };
  const metadata = { search: vi.fn() };
  const registry = { all: vi.fn() };
  const config = { getConfig: vi.fn() };
  let service: KoreaderRequestsService;

  it('creates a manual replacement from permission-checked server metadata without a normal submit', async () => {
    catalog.getBookDetail.mockResolvedValue({ title: 'A Christmas Carol', authors: ['Charles Dickens'] });
    requests.requestBookReplacement.mockResolvedValue({ request: item, subscribed: false });
    await service.replaceBook(42, 'en', user);
    expect(catalog.getBookDetail).toHaveBeenCalledWith(user, 42);
    expect(requests.requestBookReplacement).toHaveBeenCalledWith(
      42,
      { title: 'A Christmas Carol', authors: ['Charles Dickens'], mediaKind: 'ebook', language: 'en' },
      user,
    );
    expect(requests.submit).not.toHaveBeenCalled();
  });

  beforeEach(async () => {
    vi.resetAllMocks();
    const module = await Test.createTestingModule({
      providers: [
        KoreaderRequestsService,
        { provide: KoreaderCatalogService, useValue: catalog },
        PermissionService,
        { provide: RequestAutomationService, useValue: { considerRequest: vi.fn() } },
        { provide: RequestVerificationService, useValue: verification },
        { provide: BookRequestService, useValue: requests },
        { provide: RequestFulfillmentService, useValue: fulfillment },
        { provide: MetadataFetchService, useValue: metadata },
        { provide: ProviderRegistry, useValue: registry },
        { provide: ProviderConfigService, useValue: config },
      ],
    }).compile();
    service = module.get(KoreaderRequestsService);
    requests.submit.mockResolvedValue({ request: item, subscribed: false });
    requests.getOne.mockResolvedValue(item);
    requests.listMine.mockResolvedValue({ items: [item], total: 21 });
  });

  it('keeps replacement requests scoped to the device user and delegates normal approval', async () => {
    requests.requestReplacement.mockResolvedValue({ request: { ...item, status: 'pending', language: 'en' }, subscribed: false });
    expect((await service.replace(12, 'en', user)).request.status).toBe('pending');
    expect(requests.requestReplacement).toHaveBeenCalledWith(12, 'en', user);
    requests.getOne.mockResolvedValue({ ...item, userId: 999, subscribers: [] });
    await expect(service.replace(12, 'en', user)).rejects.toThrow('not found');
    expect(requests.requestReplacement).toHaveBeenCalledTimes(1);
  });

  it('does not let a device bypass fulfillment permission to discard a held import', async () => {
    requests.assertCanFulfil.mockRejectedValue(new Error('Cannot fulfil'));
    await expect(service.discardHeld(12, user)).rejects.toThrow('Cannot fulfil');
    expect(verification.discardHeldImport).not.toHaveBeenCalled();
  });

  it('requires device authentication on every route', () => {
    expect(Reflect.getMetadata(GUARDS_METADATA, KoreaderRequestsController)).toEqual([KoreaderAuthGuard]);
  });

  it('lets unified search perform one final availability batch while standalone search still checks it', async () => {
    registry.all.mockReturnValue([{ key: 'openlibrary' }]);
    config.getConfig.mockResolvedValue({});
    requests.checkAvailability.mockResolvedValue([{ ownedBookId: null }]);
    const candidate = { kind: 'candidate', candidate: { title: 'Dracula', authors: ['Bram Stoker'], provider: 'openLibrary', providerId: 'OL123W' } };
    metadata.search.mockReturnValue(of(candidate));
    await service.search({ q: 'Dracula', field: 'title' }, user, false);
    expect(requests.checkAvailability).not.toHaveBeenCalled();
    await service.search({ q: 'Dracula', field: 'title' }, user);
    expect(requests.checkAvailability).toHaveBeenCalledTimes(1);
  });
  it('enforces request permission even though global JWT permission checks are skipped', async () => {
    const denied = makeUser({ id: 7, permissions: [Permission.KoreaderSync] });
    expect(() => service.options(denied)).toThrow('permission');
    await expect(service.search({ q: 'Dickens', field: 'author' }, denied)).rejects.toThrow('permission');
    await expect(service.create({ title: item.title }, denied)).rejects.toThrow('permission');
    await expect(service.list(1, denied)).rejects.toThrow('permission');
    await expect(service.get(12, denied)).rejects.toThrow('permission');
    expect(requests.submit).not.toHaveBeenCalled();
    expect(metadata.search).not.toHaveBeenCalled();
  });

  it('uses the existing approval workflow and strips private request/download data', async () => {
    expect(service.options(user).automaticApproval).toBe(false);
    const result = await service.create({ title: item.title, authors: item.authors }, user);
    expect(requests.submit).toHaveBeenCalledWith(
      { title: item.title, authors: item.authors, mediaKind: 'ebook', preferredFormats: ['epub'], selfServe: false },
      user,
    );
    expect(result.request.status).toBe('pending');
    expect(JSON.stringify(result)).not.toContain('private');
    expect(result.request).not.toHaveProperty('subscribers');
    expect(result.request.bookId).toBeNull();
    expect(service.options(makeUser({ permissions: [Permission.BookRequestAccess, Permission.BookRequestAutoApprove] })).automaticApproval).toBe(
      true,
    );
  });

  it('paginates the caller-owned request list and opens only imported books', async () => {
    const result = await service.list(2, user);
    expect(requests.listMine).toHaveBeenCalledWith(expect.objectContaining({ page: 2, limit: 20 }), user);
    expect(result).toMatchObject({ total: 21, page: 2, pageSize: 20 });
    requests.getOne.mockResolvedValue({ ...item, status: 'available', matchedBookId: 90 });
    expect(await service.get(12, user)).toMatchObject({ bookId: 90, status: 'available' });
  });

  it('does not expose unrelated requests even to an administrator device', async () => {
    requests.getOne.mockResolvedValue({ ...item, userId: 99 });
    await expect(service.get(12, makeUser({ id: 7, isSuperuser: true }))).rejects.toThrow('not found');
    requests.getOne.mockResolvedValue({ ...item, userId: 99, subscribers: [{ userId: 7 }] });
    expect((await service.get(12, user)).id).toBe(12);
  });

  it('searches enabled metadata providers, deduplicates results and checks scoped availability', async () => {
    registry.all.mockReturnValue([{ key: 'openlibrary' }, { key: 'googlebooks' }]);
    config.getConfig.mockResolvedValue({ googlebooks: { enabled: false } });
    const candidate = { title: item.title, authors: item.authors, provider: 'openlibrary', providerId: 'OL1', sourceUrl: 'private-source' };
    metadata.search.mockReturnValue(of({ kind: 'candidate', candidate }, { kind: 'candidate', candidate }, { kind: 'run' }));
    requests.checkAvailability.mockResolvedValue([{ ownedBookId: null, existingRequestId: 12, alreadySubscribed: true }]);
    const result = await service.search({ q: ' Dickens ', field: 'author' }, user);
    expect(metadata.search).toHaveBeenCalledWith(expect.objectContaining({ author: 'Dickens', mediaKind: 'ebook', resultsPerProvider: 15 }), [
      'openlibrary',
    ]);
    expect(result.items).toHaveLength(1);
    expect(result.items[0].availability.existingRequestId).toBe(12);
    expect(JSON.stringify(result)).not.toContain('private-source');
    expect(requests.checkAvailability).toHaveBeenCalledWith(expect.any(Array), user);
  });

  it('marks partial results and caps the availability batch', async () => {
    registry.all.mockReturnValue([{ key: 'openlibrary' }]);
    config.getConfig.mockResolvedValue({});
    metadata.search.mockReturnValue(
      of(
        ...Array.from({ length: 80 }, (_, n) => ({
          kind: 'candidate',
          candidate: { title: `Book ${n}`, provider: 'openlibrary', providerId: String(n) },
        })),
        { kind: 'status' },
      ),
    );
    requests.checkAvailability.mockImplementation((items: unknown[]) => Promise.resolve(items.map(() => ({ ownedBookId: null }))));
    const result = await service.search({ q: 'Book', field: 'title' }, user);
    expect(result.items).toHaveLength(50);
    expect(result.partial).toBe(true);
    expect(result.limited).toBe(true);
  });

  it('hides known language mismatches while labelling unknown-language releases honestly', async () => {
    const admin = makeUser({ id: 7, isSuperuser: true });
    requests.getOne.mockResolvedValue({ ...item, status: 'failed', language: 'en' });
    fulfillment.listReleases.mockResolvedValue({
      releases: [
        { indexerId: 2, guid: 'english', title: 'English', language: 'eng' },
        { indexerId: 2, guid: 'catalan', title: 'Catalan', language: 'ca' },
        { indexerId: 2, guid: 'unknown', title: 'Unknown', language: null },
      ],
      indexers: [{ ok: true }],
      enabledIndexerCount: 1,
    });
    fulfillment.findTriedReleaseKeys.mockResolvedValue(new Set());
    const result = await service.releases(12, 1, false, admin);
    expect(result.items.map((release) => release.title)).toEqual(['English', 'Unknown']);
    expect(result.total).toBe(2);
  });

  it('offers opaque manual release choices, including failed attempts, without source credentials', async () => {
    const admin = makeUser({ id: 7, isSuperuser: true });
    requests.getOne.mockResolvedValue({ ...item, status: 'failed' });
    const release = {
      indexerId: 2,
      indexerName: 'Source',
      guid: 'credential-bearing-guid',
      title: 'Carol EPUB',
      format: 'epub',
      sizeBytes: 1000,
      score: 83,
      downloadUrl: 'https://private/?secret=credential',
    };
    fulfillment.listReleases.mockResolvedValue({ releases: [release], indexers: [{ ok: true }], enabledIndexerCount: 1 });
    fulfillment.findTriedReleaseKeys.mockResolvedValue(new Set([`2:${release.guid}`]));
    const result = await service.releases(12, 1, false, admin);
    expect(result.items[0]).toMatchObject({ triedBefore: true, title: 'Carol EPUB', format: 'epub' });
    expect(result.items[0].releaseId).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.stringify(result)).not.toMatch(/credential|private|downloadUrl/);
    expect((await service.get(12, admin)).canChooseRelease).toBe(true);
    fulfillment.grab.mockResolvedValue({ ...item, status: 'downloading' });
    expect((await service.grab(12, result.items[0].releaseId, admin)).status).toBe('downloading');
    expect(fulfillment.grab).toHaveBeenCalledWith(12, { indexerId: 2, releaseGuid: release.guid }, admin);
    await expect(service.grab(12, 'f'.repeat(64), admin)).rejects.toThrow('no longer available');
    expect(fulfillment.grab).toHaveBeenCalledTimes(1);
  });

  it('does not bypass approval, active downloads or existing fulfilment permissions', async () => {
    const admin = makeUser({ id: 7, isSuperuser: true });
    for (const status of ['pending', 'downloading', 'needs_review', 'available', 'cancelled']) {
      requests.getOne.mockResolvedValue({ ...item, status });
      expect((await service.get(12, admin)).canChooseRelease).toBe(false);
      await expect(service.grab(12, 'f'.repeat(64), admin)).rejects.toThrow('not ready');
    }
    requests.getOne.mockResolvedValue({ ...item, status: 'failed' });
    expect((await service.get(12, user)).canChooseRelease).toBe(false);
    requests.assertCanFulfil.mockRejectedValue(new Error('permission denied'));
    await expect(service.releases(12, 1, false, user)).rejects.toThrow('permission denied');
    await expect(service.grab(12, 'f'.repeat(64), user)).rejects.toThrow('permission denied');
    expect(fulfillment.grab).not.toHaveBeenCalled();
  });

  it('rejects privilege controls, source URLs, oversized queries and invalid pages at the HTTP boundary', async () => {
    const pipe = new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true });
    for (const key of ['userId', 'selfServe', 'targetLibraryId', 'downloadUrl', 'releaseGuid']) {
      await expect(pipe.transform({ title: item.title, [key]: 'injected' }, { type: 'body', metatype: KoreaderCreateRequestDto })).rejects.toThrow();
    }
    await expect(pipe.transform({ q: 'x'.repeat(201) }, { type: 'query', metatype: KoreaderRequestSearchDto })).rejects.toThrow();
    await expect(pipe.transform({ page: '0' }, { type: 'query', metatype: KoreaderRequestPageDto })).rejects.toThrow();
    expect(await pipe.transform({ page: '2' }, { type: 'query', metatype: KoreaderRequestPageDto })).toMatchObject({ page: 2 });
  });
  it('filters the inbox on the server and permits the original requester to cancel', async () => {
    await service.list(2, user, 'processing');
    expect(requests.listMine).toHaveBeenCalledWith(
      expect.objectContaining({ page: 2, statuses: ['approved', 'searching', 'grabbed', 'downloading', 'importing', 'needs_review'] }),
      user,
    );
    requests.cancel.mockResolvedValue({ ...item, status: 'cancelled' });
    expect((await service.cancel(12, user)).status).toBe('cancelled');
    expect(requests.cancel).toHaveBeenCalledWith(12, user);
  });
  it('does not retry an acquisition when core fulfilment authorization is refused', async () => {
    requests.getOne.mockResolvedValue({ ...item, status: 'failed' });
    requests.assertCanFulfil.mockRejectedValue(new Error('forbidden'));
    await expect(service.retry(12, user)).rejects.toThrow('forbidden');
  });
});
