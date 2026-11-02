import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { ProviderConfigService } from '../metadata-preferences/provider-config.service';
import { fetchWithThrottle } from '../metadata-fetch/fetch-with-throttle';
vi.mock('../metadata-fetch/fetch-with-throttle', () => ({ fetchWithThrottle: vi.fn() }));
describe('external device catalog', () => {
  const config = { getConfig: vi.fn() };
  let service: KoreaderExternalCatalogService;
  beforeEach(() => {
    vi.resetAllMocks();
    config.getConfig.mockResolvedValue({ openLibrary: { enabled: true } });
    service = new KoreaderExternalCatalogService(config as unknown as ProviderConfigService);
  });
  it('caches and coalesces public metadata while checking provider enablement each time', async () => {
    vi.mocked(fetchWithThrottle).mockResolvedValue(new Response(JSON.stringify({ docs: [], numFound: 0 })));
    await Promise.all([service.search('Dickens', 'author', 1), service.search('Dickens', 'author', 1)]);
    await service.search('Dickens', 'author', 1);
    expect(fetchWithThrottle).toHaveBeenCalledTimes(1);
    config.getConfig.mockResolvedValue({ openLibrary: { enabled: false } });
    await expect(service.search('Dickens', 'author', 1)).rejects.toThrow('disabled');
  });
  it('loads a Roulette synopsis without requesting edition lists and shares the work cache', async () => {
    vi.mocked(fetchWithThrottle).mockImplementation((url) =>
      Promise.resolve(
        new Response(
          JSON.stringify(
            String(url).includes('editions.json')
              ? { entries: [], size: 0 }
              : { key: '/works/OL123W', title: 'Dracula', description: 'Public-domain prose' },
          ),
        ),
      ),
    );
    expect(await service.synopsis('OL123W')).toBe('Public-domain prose');
    expect(fetchWithThrottle).toHaveBeenCalledTimes(1);
    await service.detail('OL123W', 1);
    expect(fetchWithThrottle).toHaveBeenCalledTimes(2);
  });
  it('combines escaped genre, title and language filters with publication sorting', async () => {
    vi.mocked(fetchWithThrottle).mockResolvedValue(new Response(JSON.stringify({ docs: [], numFound: 0 })));
    await service.search('Fiction', 'subject', 1, undefined, 'new', { language: 'en', refine: 'Time Machine', genre: 'Science Fiction' });
    const url = new URL(String(vi.mocked(fetchWithThrottle).mock.calls[0][0]));
    expect(url.searchParams.get('q')).toBe('subject:"Fiction" AND language:eng AND title:"Time Machine" AND subject:"Science Fiction"');
    expect(url.searchParams.get('sort')).toBe('new');
  });
  it('does not cache an outage and retries when requested', async () => {
    vi.mocked(fetchWithThrottle)
      .mockResolvedValueOnce(new Response('', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ docs: [], numFound: 0 })));
    await expect(service.search('Dickens', 'author', 1)).rejects.toThrow();
    await service.search('Dickens', 'author', 1);
    expect(fetchWithThrottle).toHaveBeenCalledTimes(2);
  });
  it('keeps catalog pagination and series terms bounded and escaped', async () => {
    vi.mocked(fetchWithThrottle).mockResolvedValue(new Response(JSON.stringify({ docs: [], numFound: 41 })));
    const result = await service.search('Series" OR *:*', 'series', 2, 'Writer');
    expect(result.hasMore).toBe(true);
    const address = new URL(String(vi.mocked(fetchWithThrottle).mock.calls[0][0]));
    expect(address.searchParams.get('page')).toBe('2');
    expect(address.searchParams.get('q')).toBe('series:"Series  OR *:*" AND author:"Writer"');
  });
  it('refuses private hosts, credentialed URLs and arbitrary redirect targets for covers', async () => {
    for (const address of [
      'https://localhost/x',
      'https://covers.openlibrary.org:99/x',
      'https://secret@covers.openlibrary.org/x',
      'http://covers.openlibrary.org/x',
    ])
      await expect(service.coverUrl(address)).rejects.toThrow();
    expect(fetchWithThrottle).not.toHaveBeenCalled();
  });
  it('follows the real Open Library archive cover redirect without forwarding user credentials', async () => {
    vi.mocked(fetchWithThrottle)
      .mockResolvedValueOnce(new Response(null, { status: 302, headers: { location: 'https://archive.org/download/cover.jpg' } }))
      .mockResolvedValueOnce(new Response(null, { status: 302, headers: { location: 'https://ia800001.us.archive.org/cover.jpg' } }))
      .mockResolvedValueOnce(new Response(new Uint8Array([255, 216, 255]), { headers: { 'content-type': 'image/jpeg' } }));
    expect(await service.coverUrl('https://covers.openlibrary.org/b/id/1-M.jpg')).toEqual(Buffer.from([255, 216, 255]));
    expect(fetchWithThrottle).toHaveBeenCalledTimes(3);
    for (const [, options] of vi.mocked(fetchWithThrottle).mock.calls) expect(options?.headers).toBeUndefined();
  });
  it('rejects redirects to private or unrelated hosts before fetching them', async () => {
    for (const target of ['https://127.0.0.1/private', 'https://example.org/x', 'http://archive.org/x', 'https://user@archive.org/x']) {
      vi.mocked(fetchWithThrottle)
        .mockReset()
        .mockResolvedValue(new Response(null, { status: 302, headers: { location: target } }));
      await expect(service.coverUrl('https://covers.openlibrary.org/b/id/1-M.jpg')).rejects.toThrow();
      expect(fetchWithThrottle).toHaveBeenCalledTimes(1);
    }
  });
});
