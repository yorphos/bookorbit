import { ForbiddenException, ValidationPipe } from '@nestjs/common';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderRouletteService } from './koreader-roulette.service';
import { rouletteKey } from './koreader-roulette.repository';
import { RouletteDecisionDto, RouletteAcquireDto } from './dto/koreader-roulette.dto';
describe('Roulette isolation, explicit acquisition and availability', () => {
  const user = { id: 4 } as RequestUser;
  let repo: any, hub: any, external: any, catalog: any, requests: any, core: any, permissions: any, service: KoreaderRouletteService;
  const book = (title: string) => ({
    title,
    authors: ['Public-domain author'],
    genres: ['Adventure'],
    providerKey: 'openLibrary',
    providerId: 'OL123W',
  });
  beforeEach(() => {
    repo = {
      records: vi.fn().mockResolvedValue([]),
      get: vi.fn().mockResolvedValue(undefined),
      excluded: vi.fn().mockResolvedValue(new Set()),
      decide: vi.fn().mockResolvedValue({ eventId: 'test' }),
      undo: vi.fn(),
      matches: vi.fn(),
    };
    hub = { discoveryCandidates: vi.fn().mockResolvedValue({ candidates: [], partial: false }) };
    external = { search: vi.fn().mockResolvedValue({ items: [] }), synopsis: vi.fn().mockResolvedValue('A public-domain story') };
    catalog = { getBooksPage: vi.fn().mockResolvedValue({ items: [] }), getBookDetail: vi.fn() };
    requests = { create: vi.fn().mockResolvedValue({ request: { id: 31, status: 'pending' } }) };
    core = { checkAvailability: vi.fn((items: any[]) => Promise.resolve(items.map(() => ({ ownedBookId: null, existingRequestId: null })))) };
    permissions = { userHas: vi.fn().mockReturnValue(true) };
    service = new KoreaderRouletteService(repo, hub, external, catalog, requests, core, permissions);
  });
  it('excludes owned, requested and disliked works from external recommendations', async () => {
    external.search.mockResolvedValue({ items: ['Owned', 'Requested', 'Disliked', 'New'].map(book) });
    repo.excluded.mockResolvedValue(new Set([rouletteKey(book('Disliked'))]));
    core.checkAvailability.mockImplementation((items: any[]) =>
      Promise.resolve(items.map((b) => ({ ownedBookId: b.title === 'Owned' ? 1 : null, existingRequestId: b.title === 'Requested' ? 2 : null }))),
    );
    const result = await service.queue(user);
    expect(result.items.map((b) => b.title)).toEqual(['New']);
    expect(repo.excluded).toHaveBeenCalledWith(user.id, expect.any(Array));
    expect(requests.create).not.toHaveBeenCalled();
  });
  it('reuses reading metadata, deduplicates candidate queries and only sends the visible card', async () => {
    const reading = { items: [{ id: 7, lastReadAt: '2026-01-01', readStatus: 'reading' }] };
    catalog.getBooksPage.mockResolvedValue(reading);
    catalog.getBookDetail.mockResolvedValue(book('Recently read'));
    external.search.mockResolvedValue({ items: Array.from({ length: 20 }, (_, i) => book('Candidate ' + i)) });
    const result = await service.queue(user);
    expect(hub.discoveryCandidates).toHaveBeenCalledWith(user, reading, [book('Recently read')]);
    expect(catalog.getBookDetail).toHaveBeenCalledTimes(1);
    expect(external.search).toHaveBeenCalledTimes(1);
    expect(core.checkAvailability).toHaveBeenCalledTimes(1);
    expect(external.synopsis).toHaveBeenCalledTimes(1);
    expect(result.items).toHaveLength(1);
    expect(result.items[0].description).toBe('A public-domain story');
  });
  it('Match only saves user feedback and never starts acquisition', async () => {
    await service.decide(user, { eventId: 'test', decision: 'match', book: book('Frankenstein') });
    expect(repo.decide).toHaveBeenCalledWith(4, expect.objectContaining({ decision: 'match' }));
    expect(requests.create).not.toHaveBeenCalled();
  });
  it('uses only this user’s saved matches for bulk acquisition and keeps them', async () => {
    repo.get.mockImplementation((id: number, key: string) =>
      Promise.resolve(key === 'book:valid' ? { book: book('Frankenstein'), decision: 'match' } : undefined),
    );
    const result = await service.acquire(user, ['valid', 'valid', 'another-users-key']);
    expect(requests.create).toHaveBeenCalledTimes(1);
    expect(requests.create).toHaveBeenCalledWith(expect.objectContaining({ title: 'Frankenstein', language: 'en' }), user);
    expect(result.results).toHaveLength(2);
    expect(result.results[1].error).toBe('Match not found');
    expect(repo.get.mock.calls.every(([id]: number[]) => id === 4)).toBe(true);
    expect(repo.decide).not.toHaveBeenCalled();
  });
  it('returns already imported books without re-requesting them', async () => {
    repo.get.mockResolvedValue({ book: book('Frankenstein'), decision: 'match' });
    core.checkAvailability.mockResolvedValue([{ ownedBookId: 31 }]);
    expect((await service.acquire(user, ['valid'])).results[0].bookId).toBe(31);
    expect(requests.create).not.toHaveBeenCalled();
  });
  it('fails closed when Book Requests access is absent', async () => {
    permissions.userHas.mockReturnValue(false);
    await expect(service.queue(user)).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.acquire(user, ['valid'])).rejects.toBeInstanceOf(ForbiddenException);
    expect(repo.get).not.toHaveBeenCalled();
  });
  it('rechecks availability for matches without removing imported matches', async () => {
    repo.matches.mockResolvedValue({ items: [{ book: book('Frankenstein'), key: 'key', decision: 'match' }], hasMore: false });
    core.checkAvailability.mockResolvedValue([{ ownedBookId: 31 }]);
    const result = await service.matches(user, { page: 1, sort: 'recent' });
    expect(result.items[0]).toMatchObject({ matchKey: 'key', bookId: 31 });
  });
  it('validates nested book data and bounded acquisition selections', async () => {
    const pipe = new ValidationPipe({ transform: true, whitelist: true, forbidNonWhitelisted: true });
    await expect(
      pipe.transform({ eventId: 'b5207ad3-3b85-45ba-9244-d8897a106fe8', decision: 'match' }, { type: 'body', metatype: RouletteDecisionDto }),
    ).rejects.toThrow();
    await expect(pipe.transform({ keys: [] }, { type: 'body', metatype: RouletteAcquireDto })).rejects.toThrow();
    await expect(pipe.transform({ keys: Array(21).fill('a'.repeat(32)) }, { type: 'body', metatype: RouletteAcquireDto })).rejects.toThrow();
  });
});
