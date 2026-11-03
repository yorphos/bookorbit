import { Test } from '@nestjs/testing';
import { ForbiddenException, ValidationPipe } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { CatalogService } from '../catalog/catalog.service';
import { CollectionService } from '../collection/collection.service';
import { UserPreferencesRepository } from '../user-preferences/user-preferences.repository';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { BookRequestService } from '../book-request/book-request.service';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderRequestsService } from './koreader-requests.service';
import { KoreaderHubService } from './koreader-hub.service';
import { DashboardWidgetService } from '../dashboard/dashboard-widget.service';
import { KoreaderDiscoveryService } from './koreader-discovery.service';
import { KoreaderSocialRepository } from './koreader-social.repository';
import { KoreaderWishlistBookDto, KoreaderWishlistKeyDto, KoreaderCollectionBookDto } from './dto/koreader-hub.dto';

describe('KOReader home, wishlist and collections', () => {
  const user = { id: 4, permissions: [Permission.BookRequestAccess], isSuperuser: false } as RequestUser;
  const catalog = { getDashboard: vi.fn(), getBooksPage: vi.fn(), getBookDetail: vi.fn() };
  const requests = { list: vi.fn() };
  const collections = { findAll: vi.fn(), addBooks: vi.fn(), removeBooks: vi.fn(), create: vi.fn() };
  const preferences = { findByCategoryPrefix: vi.fn(), findByCategory: vi.fn(), upsert: vi.fn(), delete: vi.fn() };
  const widgets = { getReadingGoal: vi.fn(), getReadingStreak: vi.fn(), getReadingDays: vi.fn() };
  const discovery = { series: vi.fn() };
  const social = { sharers: vi.fn(), activity: vi.fn(), recommendations: vi.fn() };
  const external = { search: vi.fn() };
  const core = { checkAvailability: vi.fn() };
  const catalogGenres = { listGenres: vi.fn() };
  let service: KoreaderHubService;
  beforeEach(async () => {
    vi.resetAllMocks();
    const module = await Test.createTestingModule({
      providers: [
        KoreaderHubService,
        PermissionService,
        { provide: KoreaderCatalogService, useValue: catalog },
        { provide: KoreaderRequestsService, useValue: requests },
        { provide: CollectionService, useValue: collections },
        { provide: UserPreferencesRepository, useValue: preferences },
        { provide: KoreaderExternalCatalogService, useValue: external },
        { provide: BookRequestService, useValue: core },
        { provide: CatalogService, useValue: catalogGenres },
        { provide: DashboardWidgetService, useValue: widgets },
        { provide: KoreaderDiscoveryService, useValue: discovery },
        { provide: KoreaderSocialRepository, useValue: social },
      ],
    }).compile();
    service = module.get(KoreaderHubService);
    catalog.getDashboard.mockResolvedValue({ continueReading: [], discover: [{ id: 1 }], totalBooks: 1 });
    catalog.getBooksPage.mockResolvedValue({ items: [] });
    requests.list.mockResolvedValue({ items: [] });
    external.search.mockResolvedValue({ items: [] });
    catalog.getBookDetail.mockResolvedValue({ genres: ['Science fiction'] });
    core.checkAvailability.mockImplementation((items) =>
      Promise.resolve(items.map(() => ({ ownedBookId: null, existingRequestId: null, existingRequestStatus: null, alreadySubscribed: false }))),
    );
  });
  it('lists visible library genres first, then catalog subjects not already present', async () => {
    catalogGenres.listGenres.mockResolvedValue([
      { name: 'Gothic', count: 3 },
      { name: 'fantasy', count: 1 },
    ]);
    const { items } = await service.genres(user);
    expect(catalogGenres.listGenres).toHaveBeenCalledWith(user);
    expect(items.slice(0, 2)).toEqual([
      { name: 'Gothic', count: 3, inLibrary: true },
      { name: 'fantasy', count: 1, inLibrary: true },
    ]);
    expect(items.filter((g) => g.name.toLowerCase() === 'fantasy')).toHaveLength(1);
    expect(items).toContainEqual({ name: 'Mystery', count: 0, inLibrary: false });
  });
  it('never falls back to owned books when external discovery fails', async () => {
    external.search.mockRejectedValue(new Error('offline'));
    requests.list.mockRejectedValue(new Error('offline'));
    expect(await service.home(user)).toMatchObject({
      recommendations: [],
      partial: true,
      requestsUnavailable: true,
      recommendationReason: 'Discovery temporarily unavailable',
    });
  });
  it('uses authors and genres from the last three read books, deduplicates, and excludes owned/pending works', async () => {
    const seeds = [2, 3, 4].map((id) => ({ id, title: 'Seed ' + id, authors: ['Author ' + id], lastReadAt: '2026-11-01' }));
    catalog.getBooksPage.mockImplementation((_user, query) => Promise.resolve({ items: query.sort === 'recently_read' ? seeds : [] }));
    external.search.mockImplementation((q) =>
      Promise.resolve({
        items: [
          { title: q, authors: ['Writer'] },
          { title: 'Owned', authors: ['Writer'] },
          { title: 'Pending', authors: ['Writer'] },
        ],
      }),
    );
    core.checkAvailability.mockImplementation((items) =>
      Promise.resolve(
        items.map((book) => ({ ownedBookId: book.title === 'Owned' ? 7 : null, existingRequestId: book.title === 'Pending' ? 8 : null })),
      ),
    );
    const result = await service.home(user);
    expect(external.search.mock.calls.map((call) => call[0])).toEqual(['Author 2', 'Science fiction', 'Author 3', 'Author 4']);
    expect(result.recommendations.map((book) => book.title)).toEqual(['Author 2', 'Science fiction', 'Author 3', 'Author 4']);
    expect(result.recommendationSeeds.map((book) => book.id)).toEqual([2, 3, 4]);
    expect(core.checkAvailability).toHaveBeenCalledWith(expect.any(Array), user);
  });
  it('loads Discover without dashboard counts, recent arrivals or the request inbox', async () => {
    await service.discovery(user);
    expect(catalog.getDashboard).not.toHaveBeenCalled();
    expect(requests.list).not.toHaveBeenCalled();
    expect(catalog.getBooksPage).toHaveBeenCalledTimes(1);
    expect(catalog.getBooksPage).toHaveBeenCalledWith(user, expect.objectContaining({ sort: 'recently_read', size: 3 }));
  });
  it('rechecks ownership on refresh and fails closed when that check is unavailable', async () => {
    external.search.mockResolvedValue({ items: [{ title: 'New book', authors: ['Writer'] }] });
    expect((await service.home(user)).recommendations).toHaveLength(1);
    core.checkAvailability.mockResolvedValue([{ ownedBookId: 7, existingRequestId: null }]);
    expect((await service.home(user)).recommendations).toEqual([]);
    core.checkAvailability.mockRejectedValue(new Error('offline'));
    expect(await service.home(user)).toMatchObject({ recommendations: [], partial: true });
  });
  it('uses popular external books without inventing reading history', async () => {
    catalog.getBooksPage.mockResolvedValue({ items: [{ id: 1, title: 'Never read', authors: [], lastReadAt: null }] });
    const result = await service.home(user);
    expect(external.search).toHaveBeenCalledWith('Fiction', 'subject', 1, undefined, 'popular', { language: 'en' });
    expect(result.recommendationSeeds).toEqual([]);
    expect(result.recommendationReason).toBe('Popular books outside your library');
  });
  it('does not call request APIs for an ordinary reader without request access', async () => {
    const reader = { ...user, permissions: [] };
    expect((await service.home(reader)).canRequest).toBe(false);
    preferences.findByCategoryPrefix.mockResolvedValue([{ category: 'koreader-wishlist:abc', data: { title: 'Alice' } }]);
    await service.wishlist(reader, 1);
    expect(requests.list).not.toHaveBeenCalled();
    expect(external.search).not.toHaveBeenCalled();
    expect(core.checkAvailability).not.toHaveBeenCalled();
  });
  it('stores simultaneous additions independently and scopes every mutation to the caller', async () => {
    const [alice, frankenstein] = await Promise.all([
      service.saveWishlist(user, { title: 'Alice', authors: ['Lewis Carroll'] }),
      service.saveWishlist(user, { title: 'Frankenstein', authors: ['Mary Shelley'] }),
    ]);
    expect(alice.key).not.toBe(frankenstein.key);
    const other = { ...user, id: 9 };
    expect(await service.saveWishlist(other, { title: 'Alice', authors: ['Lewis Carroll'] })).toEqual(alice);
    expect(preferences.upsert.mock.calls.map((call) => call[0])).toEqual([4, 4, 9]);
    await service.removeWishlist(other, alice.key);
    expect(preferences.delete).toHaveBeenCalledWith(9, 'koreader-wishlist:' + alice.key);
  });
  it('paginates wishlist metadata but recomputes ownership and request status', async () => {
    preferences.findByCategoryPrefix.mockResolvedValue(
      Array.from({ length: 21 }, (_, i) => ({ category: 'koreader-wishlist:' + i, data: { title: 'Book ' + i } })),
    );
    core.checkAvailability.mockResolvedValue(Array.from({ length: 20 }, () => ({ ownedBookId: null })));
    const first = await service.wishlist(user, 2);
    expect(first.items).toHaveLength(20);
    expect(first.hasMore).toBe(true);
    expect(preferences.findByCategoryPrefix).toHaveBeenCalledWith(4, 'koreader-wishlist:', 21, 20);
    core.checkAvailability.mockResolvedValue([{ ownedBookId: 17 }]);
    expect((await service.wishlist(user, 2)).items[0].availability).toEqual({ ownedBookId: 17 });
  });
  it('rejects an inaccessible book before calling the collection writer', async () => {
    catalog.getBookDetail.mockRejectedValue(new ForbiddenException());
    await expect(service.addToCollection(user, 8, 20)).rejects.toThrow();
    expect(collections.addBooks).not.toHaveBeenCalled();
  });
  it('preserves collection ownership enforcement for both additions and removals', async () => {
    collections.addBooks.mockRejectedValue(new ForbiddenException('Cannot modify this collection'));
    collections.removeBooks.mockRejectedValue(new ForbiddenException('Cannot modify this collection'));
    await expect(service.addToCollection(user, 8, 20)).rejects.toThrow('Cannot modify');
    await expect(service.removeFromCollection(user, 8, 20)).rejects.toThrow('Cannot modify');
    expect(collections.addBooks).toHaveBeenCalledWith(8, { bookIds: [20] }, user);
    expect(collections.removeBooks).toHaveBeenCalledWith(8, { bookIds: [20] }, user);
  });
  it('rejects client-selected identities, acquisition URLs and arbitrary preference keys', async () => {
    const pipe = new ValidationPipe({ transform: true, whitelist: true, forbidNonWhitelisted: true });
    await expect(pipe.transform({ title: 'Alice', userId: 9 }, { type: 'body', metatype: KoreaderWishlistBookDto })).rejects.toThrow();
    await expect(
      pipe.transform({ title: 'Alice', downloadUrl: 'https://example.org/book.epub' }, { type: 'body', metatype: KoreaderWishlistBookDto }),
    ).rejects.toThrow();
    await expect(pipe.transform({ key: '../preferences' }, { type: 'param', metatype: KoreaderWishlistKeyDto })).rejects.toThrow();
    await expect(pipe.transform({ bookId: 1, userId: 9 }, { type: 'body', metatype: KoreaderCollectionBookDto })).rejects.toThrow();
  });
  it('serves Home from the last recommendations and refreshes them in the background', async () => {
    catalog.getBooksPage.mockResolvedValue({ items: [{ id: 3, title: 'Read', authors: ['Ann'], lastReadAt: '2026-01-01' }] });
    external.search.mockResolvedValue({ items: [{ title: 'New', authors: ['Ann'], providerKey: 'openLibrary', providerId: 'OL1W' }] });
    widgets.getReadingStreak.mockResolvedValue({ currentStreak: 3, longestStreak: 9, lastSevenDays: [] });
    widgets.getReadingGoal.mockResolvedValue({ goalBooks: 24, completedBooks: 5, year: 2026 });
    requests.list.mockImplementation((_page: number, _user: RequestUser, filter?: string) =>
      Promise.resolve({
        items:
          filter === 'ready'
            ? [
                { id: 9, status: 'available', bookId: 44 },
                { id: 10, status: 'available', bookId: null },
              ]
            : [],
      }),
    );
    const first = await service.home(user);
    const searches = external.search.mock.calls.length;
    const second = await service.home(user);
    expect(external.search.mock.calls.length).toBe(searches);
    expect(second.recommendations).toEqual(first.recommendations);
    expect(first.ready.map((r: { id: number }) => r.id)).toEqual([9]);
    expect(first.streak).toEqual({ current: 3, longest: 9 });
    expect(first.goal).toEqual({ goal: 24, done: 5, year: 2026 });
  });
  it('sums reading minutes for the Stats screen from the dashboard reading days', async () => {
    widgets.getReadingGoal.mockResolvedValue({ goalBooks: null, completedBooks: 2, year: 2026 });
    widgets.getReadingStreak.mockResolvedValue({ currentStreak: 1, longestStreak: 4, lastSevenDays: [true] });
    widgets.getReadingDays.mockResolvedValue({ startDate: '2025-10-27', minutes: [...Array(369).fill(0), 10, 20] });
    catalog.getBooksPage.mockResolvedValue({ items: [], total: 3 });
    const stats = await service.stats(user);
    expect(stats.minutes).toEqual({ today: 20, week: 30, month: 30, year: 30 });
    expect(stats.readingDaysThisYear).toBe(2);
    expect(stats.lastFourteenDays).toHaveLength(14);
    expect(stats.finishedTotal).toBe(3);
  });
  it('suggests the next owned volume after a finished book', async () => {
    catalog.getBookDetail.mockResolvedValue({
      id: 5,
      title: 'Book Two',
      authors: ['Ann'],
      seriesName: 'Saga',
      seriesIndex: 2,
      seriesMembers: [
        { id: 4, title: 'Book One', seriesIndex: 1, readStatus: 'read' },
        { id: 7, title: 'Book Four', seriesIndex: 4, readStatus: null },
        { id: 6, title: 'Book Three', seriesIndex: 3, readStatus: null },
      ],
    });
    const next = await service.next(user, 5);
    expect(next.nextInSeries).toEqual(expect.objectContaining({ bookId: 6, title: 'Book Three' }));
    expect(discovery.series).not.toHaveBeenCalled();
  });
  it('shows other readers only to a reader who shares, and only books the viewer can open', async () => {
    preferences.findByCategory.mockResolvedValue(undefined);
    expect(await service.socialFeed(user)).toEqual({ share: false, people: [], items: [] });
    expect(social.sharers).not.toHaveBeenCalled();
    preferences.findByCategory.mockResolvedValue({ data: { share: true } });
    social.sharers.mockResolvedValue([{ userId: 8, name: 'Bea', username: 'bea' }]);
    social.activity.mockResolvedValue([
      { userId: 8, bookId: 1, status: 'read', updatedAt: new Date('2026-10-01'), finishedAt: new Date('2026-10-01') },
      { userId: 8, bookId: 2, status: 'reading', updatedAt: new Date('2026-10-02'), finishedAt: null },
    ]);
    social.recommendations.mockResolvedValue([{ userId: 8, bookId: 3, note: 'Loved it', at: '2026-10-03T00:00:00.000Z' }]);
    catalog.getBooksPage.mockResolvedValue({
      items: [
        { id: 1, title: 'Visible' },
        { id: 3, title: 'Also visible' },
      ],
    });
    const feed = await service.socialFeed(user);
    expect(social.sharers).toHaveBeenCalledWith(4);
    expect(feed.items.map((i: { id: number; kind: string }) => [i.id, i.kind])).toEqual([
      [3, 'recommended'],
      [1, 'finished'],
    ]);
    expect(feed.items[0]).toEqual(expect.objectContaining({ friend: 'Bea', note: 'Loved it' }));
  });
  it('refuses a recommendation until the reader shares', async () => {
    catalog.getBookDetail.mockResolvedValue({ id: 3 });
    preferences.findByCategory.mockResolvedValue(undefined);
    await expect(service.recommend(user, 3)).rejects.toBeInstanceOf(ForbiddenException);
    expect(preferences.upsert).not.toHaveBeenCalled();
  });
  it('rate limits plugin error reports per reader', () => {
    const results = Array.from({ length: 32 }, () => service.reportError(user, { message: 'boom' }).accepted);
    expect(results.filter(Boolean)).toHaveLength(30);
  });
  it('creates a Kobo collection with the default folder icon', async () => {
    collections.create.mockResolvedValue({ id: 12, name: 'Beach reads' });
    expect(await service.createCollection(user, '  Beach reads ')).toEqual({ id: 12, name: 'Beach reads', bookCount: 0 });
    expect(collections.create).toHaveBeenCalledWith({ name: 'Beach reads', icon: 'FolderOpen' }, user);
  });
});
