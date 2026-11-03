import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rename, stat, unlink, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import sharp from 'sharp';

// Covers are drawn at most this size on a Kobo: about a third of a 1072 px wide screen.
const MAX_WIDTH = 360;
const MAX_HEIGHT = 540;
const QUALITY = 74;
const MAX_FILES = 3000;
const PRUNE_TO = 2400;
const TTL_MS = 30 * 24 * 3600 * 1000;

/**
 * Public catalog covers for KOReader, kept on disk already resized and in greyscale,
 * so a Kobo downloads a small JPEG and the remote host is asked once a month at most.
 * Only public cover images are stored: nothing about who asked for them.
 */
@Injectable()
export class KoreaderCoverCacheService {
  private readonly logger = new Logger(KoreaderCoverCacheService.name);
  private readonly dir: string;
  private readonly pending = new Map<string, Promise<Buffer>>();
  private writes = 0;

  constructor(config: ConfigService) {
    this.dir = join(config.get<string>('storage.appDataPath') ?? '/data', 'cache', 'koreader-covers');
  }

  key(address: string) {
    return createHash('sha256').update(address).digest('hex');
  }

  /** The Kobo-sized JPEG for a remote cover, from the cache or made from fetch(). */
  async get(address: string, fetch: () => Promise<Buffer>): Promise<Buffer> {
    const key = this.key(address);
    const path = join(this.dir, key + '.jpg');
    try {
      const info = await stat(path);
      if (Date.now() - info.mtimeMs < TTL_MS) {
        const bytes = await readFile(path);
        // Touch on read so pruning drops the covers nobody looks at.
        utimes(path, new Date(), info.mtime).catch(() => undefined);
        return bytes;
      }
    } catch {
      // Not cached yet.
    }
    const running = this.pending.get(key);
    if (running) return running;
    const work = (async () => {
      const original = await fetch();
      const small = await KoreaderCoverCacheService.shrink(original);
      await this.store(path, small);
      return small;
    })().finally(() => this.pending.delete(key));
    this.pending.set(key, work);
    return work;
  }

  /** Greyscale JPEG that fits MAX_WIDTH x MAX_HEIGHT. A cover sharp cannot read is passed through. */
  static async shrink(bytes: Buffer): Promise<Buffer> {
    try {
      return await sharp(bytes, { failOn: 'none' })
        .rotate()
        .resize({ width: MAX_WIDTH, height: MAX_HEIGHT, fit: 'inside', withoutEnlargement: true })
        .greyscale()
        .toColourspace('b-w')
        .jpeg({ quality: QUALITY, mozjpeg: true })
        .toBuffer();
    } catch {
      return bytes;
    }
  }

  private async store(path: string, bytes: Buffer) {
    try {
      await mkdir(this.dir, { recursive: true });
      const temp = path + '.' + process.pid + '.part';
      await writeFile(temp, bytes);
      await rename(temp, path);
      if (++this.writes % 50 === 0) void this.prune();
    } catch (error) {
      this.logger.warn(`Could not cache a KOReader cover: ${(error as Error).message}`);
    }
  }

  async prune() {
    try {
      const names = (await readdir(this.dir)).filter((name) => name.endsWith('.jpg'));
      if (names.length <= MAX_FILES) return;
      const files = await Promise.all(
        names.map(async (name) => ({ name, atime: (await stat(join(this.dir, name)).catch(() => null))?.atimeMs ?? 0 })),
      );
      files.sort((a, b) => a.atime - b.atime);
      await Promise.all(files.slice(0, files.length - PRUNE_TO).map((file) => unlink(join(this.dir, file.name)).catch(() => undefined)));
    } catch {
      // The cache is optional.
    }
  }
}
