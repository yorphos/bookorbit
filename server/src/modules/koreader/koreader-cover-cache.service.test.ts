import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { KoreaderCoverCacheService } from './koreader-cover-cache.service';

describe('KoreaderCoverCacheService', () => {
  let dir: string;
  let service: KoreaderCoverCacheService;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'covers-'));
    service = new KoreaderCoverCacheService({ get: () => dir } as never);
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('shrinks a cover to a greyscale JPEG once and serves later requests from disk', async () => {
    const original = await sharp({ create: { width: 800, height: 1200, channels: 3, background: { r: 200, g: 20, b: 20 } } })
      .png()
      .toBuffer();
    const fetch = vi.fn().mockResolvedValue(original);
    const first = await service.get('https://covers.openlibrary.org/b/id/1-M.jpg', fetch);
    const second = await service.get('https://covers.openlibrary.org/b/id/1-M.jpg', fetch);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(second.equals(first)).toBe(true);
    const meta = await sharp(first).metadata();
    expect(meta.format).toBe('jpeg');
    expect(meta.width).toBeLessThanOrEqual(360);
    expect(meta.height).toBeLessThanOrEqual(540);
    expect(meta.channels).toBe(1);
  });
  it('shares one fetch between simultaneous requests for the same cover', async () => {
    const fetch = vi.fn().mockResolvedValue(Buffer.from('not an image'));
    const [a, b] = await Promise.all([service.get('https://x/1', fetch), service.get('https://x/1', fetch)]);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(a.toString()).toBe('not an image');
    expect(b.toString()).toBe('not an image');
  });
});
