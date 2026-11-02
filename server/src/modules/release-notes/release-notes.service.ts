import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

import type { ReleaseNote, ReleaseNotesResponse } from '@bookorbit/types';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { AppSettingsService } from '../app-settings/app-settings.service';
import { parseHighlights, stripHighlightsSection } from './highlights.parser';
import {
  CUMULATIVE_VERSION_CAP,
  MEDIA_PROBE_CONCURRENCY,
  MEDIA_TYPE_CACHE_MAX,
  PAGE_CACHE_MAX,
  RELEASE_NOTES_LIST_TTL_MS,
  RELEASE_NOTES_PER_PAGE,
  RELEASE_NOTES_TIMEOUT_MS,
  SEMVER_RE,
} from './release-notes.constants';

@Injectable()
export class ReleaseNotesService {
  private readonly logger = new Logger(ReleaseNotesService.name);
  private readonly pageCache = new Map<number, { releases: ReleaseNote[]; fetchedAt: number }>();
  private readonly mediaTypeCache = new Map<string, 'image' | 'video' | 'other'>();

  constructor(
    private readonly config: ConfigService,
    private readonly appSettingsService: AppSettingsService,
  ) {}

  async getSince(since: string | null): Promise<ReleaseNotesResponse> {
    const all = await this.getPage(1);
    const current = this.config.get<string>('app.version') ?? '';
    const capByCurrent = SEMVER_RE.test(current);

    const eligible = all.filter((r) => {
      if (r.highlights.length === 0) return false;
      if (since && !this.isNewer(r.version, since)) return false;
      // Never announce versions newer than the running build (not yet installed here).
      if (capByCurrent && this.isNewer(r.version, current)) return false;
      return true;
    });

    const releases = eligible.slice(0, CUMULATIVE_VERSION_CAP);
    return { releases, hasMore: eligible.length > releases.length };
  }

  async getAll(page: number): Promise<ReleaseNotesResponse> {
    const safePage = Number.isInteger(page) && page > 0 ? page : 1;
    const releases = await this.getPage(safePage);
    return { releases, hasMore: releases.length >= RELEASE_NOTES_PER_PAGE };
  }

  private async getPage(page: number): Promise<ReleaseNote[]> {
    const cached = this.pageCache.get(page);
    if (cached && Date.now() - cached.fetchedAt < RELEASE_NOTES_LIST_TTL_MS) {
      return cached.releases;
    }

    const fetched = await this.fetchPage(page);
    if (fetched) {
      this.setCapped(this.pageCache, page, { releases: fetched, fetchedAt: Date.now() }, PAGE_CACHE_MAX);
      return fetched;
    }

    return cached?.releases ?? [];
  }

  /** Insert into a cache map, evicting the oldest entry first when at capacity (FIFO). */
  private setCapped<K, V>(map: Map<K, V>, key: K, value: V, max: number): void {
    if (!map.has(key) && map.size >= max) {
      const oldest = map.keys().next();
      if (!oldest.done) map.delete(oldest.value);
    }
    map.set(key, value);
  }

  private async fetchPage(page: number): Promise<ReleaseNote[] | null> {
    const enabled = await this.appSettingsService.isUpdateCheckEnabled();
    if (!enabled) return [];

    const repo = this.config.get<string>('app.githubReleasesRepo') ?? 'bookorbit/bookorbit';
    const token = this.config.get<string>('app.githubReleasesToken');
    const url = `https://api.github.com/repos/${repo}/releases?per_page=${RELEASE_NOTES_PER_PAGE}&page=${page}`;
    const start = Date.now();
    this.logger.log(`[release_notes.fetch] [start] repo="${sanitizeLogValue(repo)}" page=${page} - fetching releases`);

    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), RELEASE_NOTES_TIMEOUT_MS);

      const headers: Record<string, string> = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
      if (token) headers.Authorization = `Bearer ${token}`;

      let response: Response;
      try {
        response = await fetch(url, { headers, signal: controller.signal });
      } finally {
        clearTimeout(timer);
      }

      if (!response.ok) {
        const durationMs = Date.now() - start;
        this.logger.warn(
          `[release_notes.fetch] [fail] repo="${sanitizeLogValue(repo)}" page=${page} durationMs=${durationMs} errorClass=${this.httpErrorClass(response.status)} error="GitHub API returned ${response.status}" - fetch releases failed`,
        );
        return null;
      }

      let data: unknown;
      try {
        data = await response.json();
      } catch {
        const durationMs = Date.now() - start;
        this.logger.warn(
          `[release_notes.fetch] [fail] repo="${sanitizeLogValue(repo)}" page=${page} durationMs=${durationMs} errorClass=ParseError error="invalid JSON response" - fetch releases failed`,
        );
        return null;
      }
      if (!Array.isArray(data)) {
        const durationMs = Date.now() - start;
        this.logger.warn(
          `[release_notes.fetch] [fail] repo="${sanitizeLogValue(repo)}" page=${page} durationMs=${durationMs} errorClass=ParseError error="unexpected response shape" - fetch releases failed`,
        );
        return null;
      }

      const releases = data.map((raw) => this.toReleaseNote(raw, repo)).filter((r): r is ReleaseNote => r !== null);
      await this.resolveMediaTypes(releases, token);
      const durationMs = Date.now() - start;
      this.logger.log(
        `[release_notes.fetch] [end] repo="${sanitizeLogValue(repo)}" page=${page} durationMs=${durationMs} count=${releases.length} - fetch releases completed`,
      );
      return releases;
    } catch (error) {
      const durationMs = Date.now() - start;
      const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
      const message = error instanceof Error ? error.message : String(error);
      this.logger.warn(
        `[release_notes.fetch] [fail] repo="${sanitizeLogValue(repo)}" page=${page} durationMs=${durationMs} errorClass=${errorClass} error="${sanitizeLogValue(message)}" - fetch releases failed`,
      );
      return null;
    }
  }

  private toReleaseNote(raw: unknown, repo: string): ReleaseNote | null {
    if (typeof raw !== 'object' || raw === null) return null;
    const r = raw as Record<string, unknown>;
    if (r.draft === true) return null;

    const version = typeof r.tag_name === 'string' ? r.tag_name : null;
    if (!version) return null;

    const body = typeof r.body === 'string' ? r.body : null;
    const name = typeof r.name === 'string' && r.name.trim() ? r.name : null;

    return {
      version,
      name,
      date: typeof r.published_at === 'string' ? r.published_at : null,
      highlights: parseHighlights(body),
      changelogUrl: typeof r.html_url === 'string' ? r.html_url : `https://github.com/${repo}/releases/tag/${version}`,
      changelogBody: stripHighlightsSection(body),
    };
  }

  /**
   * GitHub drag-drop media (user-attachments) has no file extension, so the parser defaults it to
   * 'image'. Probe the content-type once per URL and reclassify the ones that are actually video.
   */
  private async resolveMediaTypes(releases: ReleaseNote[], token?: string): Promise<void> {
    const pending = new Set<string>();
    for (const release of releases) {
      for (const highlight of release.highlights) {
        for (const item of highlight.media) {
          if (item.type === 'image' && this.needsContentTypeProbe(item.url) && !this.mediaTypeCache.has(item.url)) {
            pending.add(item.url);
          }
        }
      }
    }
    if (pending.size === 0) return;

    const urls = [...pending];
    for (let i = 0; i < urls.length; i += MEDIA_PROBE_CONCURRENCY) {
      await Promise.all(urls.slice(i, i + MEDIA_PROBE_CONCURRENCY).map((url) => this.probeMediaType(url, token)));
    }

    for (const release of releases) {
      for (const highlight of release.highlights) {
        for (const item of highlight.media) {
          if (item.type === 'image' && this.mediaTypeCache.get(item.url) === 'video') {
            item.type = 'video';
          }
        }
      }
    }
  }

  private needsContentTypeProbe(url: string): boolean {
    return !/\.(png|jpe?g|gif|webp|svg|avif)(?:[?#].*)?$/i.test(url);
  }

  private async probeMediaType(url: string, token?: string): Promise<void> {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), RELEASE_NOTES_TIMEOUT_MS);
      // GitHub user-attachments redirect to a presigned S3 URL that only allows GET, so HEAD
      // returns 403. A single-byte ranged GET gets the real content-type without downloading.
      const headers: Record<string, string> = { Range: 'bytes=0-0' };
      if (token) headers.Authorization = `Bearer ${token}`;

      let response: Response;
      try {
        response = await fetch(url, { method: 'GET', headers, signal: controller.signal });
      } finally {
        clearTimeout(timer);
      }

      const type = (response.headers.get('content-type') ?? '').toLowerCase();
      this.setCapped(
        this.mediaTypeCache,
        url,
        type.startsWith('video/') ? 'video' : type.startsWith('image/') ? 'image' : 'other',
        MEDIA_TYPE_CACHE_MAX,
      );
    } catch {
      this.setCapped(this.mediaTypeCache, url, 'other', MEDIA_TYPE_CACHE_MAX);
    }
  }

  private httpErrorClass(status: number): string {
    if (status === 401 || status === 403) return 'AuthError';
    if (status === 404) return 'NotFoundError';
    if (status === 429) return 'RateLimitError';
    return 'HttpError';
  }

  private isNewer(candidate: string, baseline: string): boolean {
    if (!SEMVER_RE.test(candidate)) return false;
    const a = this.parseSemver(candidate.replace(/^v/, ''));
    const b = this.parseSemver(baseline.replace(/^v/, ''));
    if (!a || !b) return false;
    if (a[0] !== b[0]) return a[0] > b[0];
    if (a[1] !== b[1]) return a[1] > b[1];
    return a[2] > b[2];
  }

  private parseSemver(version: string): [number, number, number] | null {
    // Fork builds carry a suffix (v3.6.0-yrp.1); only the upstream release part is compared.
    const match = version.match(/^(\d+)\.(\d+)\.(\d+)/);
    if (!match) return null;
    return [Number(match[1]), Number(match[2]), Number(match[3])];
  }
}
