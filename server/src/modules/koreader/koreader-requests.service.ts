import { KoreaderCatalogService } from './koreader-catalog.service';
import { RequestAutomationService } from '../book-request/fulfillment/request-automation.service';
import { createHash } from 'crypto';
import { BadGatewayException, BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import {
  Permission,
  isCancellableBookRequestStatus,
  type BookRequestStatus,
  toRequestLanguage,
  isBookRequestFulfiller,
  isGrabbableBookRequestStatus,
  type BookRequestItem,
  type MetadataCandidate,
} from '@bookorbit/types';
import { lastValueFrom, take, takeUntil, timer, toArray } from 'rxjs';

import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { RequestVerificationService } from '../book-request/fulfillment/request-verification.service';
import { RequestFulfillmentService } from '../book-request/fulfillment/request-fulfillment.service';
import { BookRequestService } from '../book-request/book-request.service';
import { MetadataFetchService } from '../metadata-fetch/metadata-fetch.service';
import { ProviderRegistry } from '../metadata-fetch/provider-registry';
import { ProviderConfigService } from '../metadata-preferences/provider-config.service';
import { KoreaderCreateRequestDto, KoreaderRequestSearchDto } from './dto/koreader-requests.dto';

@Injectable()
export class KoreaderRequestsService {
  constructor(
    private readonly requests: BookRequestService,
    private readonly fulfillment: RequestFulfillmentService,
    private readonly metadata: MetadataFetchService,
    private readonly providers: ProviderRegistry,
    private readonly providerConfig: ProviderConfigService,
    private readonly permissions: PermissionService,
    private readonly verification: RequestVerificationService,
    private readonly automation: RequestAutomationService,
    private readonly catalog: KoreaderCatalogService,
  ) {}

  // The device guard authenticates after the global permission guard skips @Public routes.
  private requireAccess(user: RequestUser): void {
    if (!this.permissions.userHas(user, Permission.BookRequestAccess)) {
      throw new ForbiddenException('Your account does not have permission to request books');
    }
  }

  options(user: RequestUser) {
    this.requireAccess(user);
    return { automaticApproval: this.permissions.userHas(user, Permission.BookRequestAutoApprove) };
  }

  async search(dto: KoreaderRequestSearchDto, user: RequestUser, includeAvailability = true) {
    this.requireAccess(user);
    const query = dto.q.trim();
    if (query.length < 2) throw new BadRequestException('Enter at least two characters');
    const config = await this.providerConfig.getConfig();
    const keys = this.providers
      .all()
      .filter((p) => config[p.key]?.enabled !== false)
      .map((p) => p.key);
    if (!keys.length) return { items: [], partial: false, limited: false, noProviders: true };
    const events = await lastValueFrom(
      this.metadata
        .search(
          {
            ...(dto.field === 'author'
              ? { author: query }
              : dto.field === 'isbn'
                ? { isbn: query }
                : { title: query, titleIsExplicitQuery: true, ...(dto.field === 'series' ? { seriesName: query } : {}) }),
            mediaKind: 'ebook',
            isAudiobook: false,
            resultsPerProvider: 15,
            maxCandidatesPerProvider: 15,
          },
          keys,
        )
        .pipe(take(100), takeUntil(timer(20_000)), toArray()),
    );
    const unique = new Map<string, MetadataCandidate>();
    for (const event of events) {
      if (event.kind !== 'candidate' || !event.candidate.title?.trim()) continue;
      const c = event.candidate;
      if (c.mediaKind && c.mediaKind !== 'ebook') continue;
      const identity = `${c.title?.trim().toLowerCase()}|${c.authors?.[0]?.trim().toLowerCase() ?? ''}|${c.language ?? ''}`;
      if (!unique.has(identity)) unique.set(identity, c);
    }
    const candidates = [...unique.values()].slice(0, 50);
    const items = candidates.map((c) => ({
      title: c.title!.slice(0, 500),
      authors: (c.authors ?? []).slice(0, 10).map((a) => a.slice(0, 255)),
      isbn10: c.isbn10?.slice(0, 20),
      isbn13: c.isbn13?.slice(0, 20),
      language: c.language?.slice(0, 20),
      description: c.description?.slice(0, 12000),
      coverUrl: c.coverUrl,
      seriesName: c.seriesName,
      seriesIndex: c.seriesIndex,
      genres: c.genres?.slice(0, 12),
      publishedYear: c.publishedYear,
      providerKey: c.provider,
      providerId: c.providerId.slice(0, 255),
    }));
    const availability =
      includeAvailability && items.length
        ? await this.requests.checkAvailability(
            items.map((c) => ({
              ...c,
              author: c.authors[0],
              mediaKind: 'ebook',
            })),
            user,
          )
        : [];
    return {
      items: items.map((c, i) => ({ ...c, availability: availability[i] })),
      partial: events.some((e) => e.kind === 'status') || events.filter((e) => e.kind === 'run').length < keys.length,
      limited: unique.size >= 50 || events.length >= 100,
      noProviders: false,
    };
  }

  async create(dto: KoreaderCreateRequestDto, user: RequestUser) {
    this.requireAccess(user);
    if (!dto.title.trim()) throw new BadRequestException('A title is required');
    const result = await this.requests.submit(
      {
        ...dto,
        title: dto.title.trim(),
        mediaKind: 'ebook',
        preferredFormats: ['epub'],
        selfServe: false,
      },
      user,
    );
    return { request: this.project(result.request, user), subscribed: result.subscribed };
  }

  async list(page: number, user: RequestUser, filter = 'all') {
    this.requireAccess(user);
    const groups: Record<string, BookRequestStatus[]> = {
      pending: ['pending'],
      processing: ['approved', 'searching', 'grabbed', 'downloading', 'importing', 'needs_review'],
      ready: ['available'],
      failed: ['failed', 'rejected', 'cancelled'],
    };
    const result = await this.requests.listMine(
      { page, limit: 20, statuses: groups[filter], mediaKind: 'ebook', sortBy: 'updatedAt', sortDir: 'desc' },
      user,
    );
    return { items: result.items.map((r) => this.project(r, user)), total: result.total, page, pageSize: 20 };
  }

  async get(id: number, user: RequestUser) {
    this.requireAccess(user);
    const request = await this.requests.getOne(id, user);
    // Even an administrator's device only follows its own requests and subscriptions.
    if (request.userId !== user.id && !request.subscribers.some((s) => s.userId === user.id)) {
      throw new NotFoundException('Book request not found');
    }
    return this.project(request, user);
  }

  /** The current state of requests a device follows. Ids it may no longer see come back as gone. */
  async watch(ids: number[], user: RequestUser) {
    this.requireAccess(user);
    const unique = [...new Set(ids)].slice(0, 50);
    const items = await Promise.all(unique.map((id) => this.get(id, user).catch(() => ({ id, gone: true as const }))));
    return { items };
  }

  async cancel(id: number, user: RequestUser) {
    await this.get(id, user);
    return this.project(await this.requests.cancel(id, user), user);
  }

  async retry(id: number, user: RequestUser) {
    await this.requireReleaseAccess(id, user);
    this.automation.considerRequest(id);
    return { ...(await this.get(id, user)), retryQueued: true };
  }

  async replaceBook(bookId: number, language: string, user: RequestUser) {
    this.requireAccess(user);
    const book = await this.catalog.getBookDetail(user, bookId);
    const result = await this.requests.requestBookReplacement(
      bookId,
      {
        title: book.title,
        authors: book.authors,
        mediaKind: 'ebook',
        language,
      },
      user,
    );
    return { request: this.project(result.request, user), subscribed: result.subscribed };
  }

  async replace(id: number, language: string, user: RequestUser) {
    await this.get(id, user);
    const result = await this.requests.requestReplacement(id, language, user);
    return { request: this.project(result.request, user), subscribed: result.subscribed };
  }

  async discardHeld(id: number, user: RequestUser) {
    await this.get(id, user);
    await this.requests.assertCanFulfil(id, user);
    await this.verification.discardHeldImport(id, user);
    return this.get(id, user);
  }

  private canChooseRelease(request: BookRequestItem, user: RequestUser): boolean {
    return (
      isGrabbableBookRequestStatus(request.status) &&
      (this.permissions.userHas(user, Permission.ManageBookRequests) ||
        (this.permissions.userHas(user, Permission.BookRequestSelfFulfill) && isBookRequestFulfiller(request, user.id)))
    );
  }

  private async requireReleaseAccess(id: number, user: RequestUser) {
    const request = await this.get(id, user);
    await this.requests.assertCanFulfil(id, user);
    if (!isGrabbableBookRequestStatus(request.status)) {
      throw new BadRequestException('This request is not ready for another release');
    }
    return request;
  }

  private releaseId(release: { indexerId: number; guid: string }): string {
    // Plugin GUIDs can contain structured source data. Only a fingerprint goes to the device.
    return createHash('sha256')
      .update(JSON.stringify([release.indexerId, release.guid]))
      .digest('hex');
  }

  async releases(id: number, page: number, refresh: boolean, user: RequestUser) {
    const request = await this.requireReleaseAccess(id, user);
    const [result, tried] = await Promise.all([this.fulfillment.listReleases(id, { refresh }), this.fulfillment.findTriedReleaseKeys(id)]).catch(
      () => {
        throw new BadGatewayException('Sources could not be searched. Try again.');
      },
    );
    const language = toRequestLanguage(request.language);
    const releases = result.releases.filter((release) => !language || !release.language || toRequestLanguage(release.language) === language);
    return {
      items: releases.slice((page - 1) * 20, page * 20).map((r) => ({
        releaseId: this.releaseId(r),
        title: r.title,
        source: r.indexerName,
        format: r.format,
        language: r.language,
        sizeBytes: r.sizeBytes,
        score: r.score,
        vipOnly: r.vipOnly,
        triedBefore: tried.has(`${r.indexerId}:${r.guid}`),
      })),
      total: releases.length,
      page,
      pageSize: 20,
      partial: result.indexers.some((i) => !i.ok),
      noSources: result.enabledIndexerCount === 0,
    };
  }

  async grab(id: number, releaseId: string, user: RequestUser) {
    const current = await this.requireReleaseAccess(id, user);
    const result = await this.fulfillment.listReleases(id).catch(() => {
      throw new BadGatewayException('Sources could not be searched. Try again.');
    });
    const release = result.releases.find((r) => this.releaseId(r) === releaseId);
    if (!release) throw new BadRequestException('Release no longer available. Refresh the release list.');
    if (current.language && release.language && toRequestLanguage(current.language) !== toRequestLanguage(release.language)) {
      throw new BadRequestException('This release is in a different language');
    }
    const request = await this.fulfillment.grab(id, { indexerId: release.indexerId, releaseGuid: release.guid }, user).catch(() => {
      throw new BadRequestException('Release could not be started. Refresh request status before trying another.');
    });
    return this.project(request, user);
  }

  private project(request: BookRequestItem, user: RequestUser) {
    // Never send source URLs, provider credentials, raw downloader errors or subscriber identities.
    return {
      canChooseRelease: this.canChooseRelease(request, user),
      canReplace: request.status === 'available' && request.matchedBookId !== null && request.mediaKind === 'ebook',
      language: request.language,
      languageNeedsReview: request.status === 'needs_review' && !!request.statusReason?.includes('requested language '),
      canDiscardHeld:
        request.status === 'needs_review' &&
        (this.permissions.userHas(user, Permission.ManageBookRequests) ||
          (this.permissions.userHas(user, Permission.BookRequestSelfFulfill) && isBookRequestFulfiller(request, user.id))),
      replacementBookId: request.targetBookId ?? null,
      canCancel:
        isCancellableBookRequestStatus(request.status) &&
        (request.userId === user.id ||
          this.permissions.userHas(user, Permission.ManageBookRequests) ||
          (this.permissions.userHas(user, Permission.BookRequestSelfFulfill) && isBookRequestFulfiller(request, user.id))),
      canRetry:
        !(request.targetBookId != null && request.targetBookId === request.matchedBookId) &&
        (request.status === 'failed' || request.status === 'approved') &&
        this.canChooseRelease(request, user),
      id: request.id,
      title: request.title,
      authors: request.authors,
      coverUrl: request.coverUrl,
      seriesName: request.seriesName,
      seriesIndex: request.seriesIndex,
      status: request.status,
      bookId: request.status === 'available' ? request.matchedBookId : null,
      downloadStatus: request.download?.status ?? null,
      progressPercent: request.download?.progressPercent ?? null,
      updatedAt: request.updatedAt,
    };
  }
}
