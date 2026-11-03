import { Body, Controller, Get, Param, ParseIntPipe, Post, Query, UseGuards, UseInterceptors } from '@nestjs/common';
import { AuditAction, AuditResource, Permission } from '@bookorbit/types';
import { Auditable } from '../../common/decorators/auditable.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRequestsService } from './koreader-requests.service';
import {
  KoreaderCreateRequestDto,
  KoreaderRequestPageDto,
  KoreaderRequestSearchDto,
  KoreaderReleasePageDto,
  KoreaderGrabReleaseDto,
  KoreaderReplacementDto,
  KoreaderRequestWatchDto,
} from './dto/koreader-requests.dto';
import { KoreaderEtagInterceptor } from './koreader-etag.interceptor';

@Public()
@UseGuards(KoreaderAuthGuard)
@RequirePermission(Permission.BookRequestAccess)
@UseInterceptors(KoreaderEtagInterceptor)
@Controller('koreader/plugin/requests')
export class KoreaderRequestsController {
  constructor(private readonly service: KoreaderRequestsService) {}

  @Get('options')
  options(@CurrentUser() user: RequestUser) {
    return this.service.options(user);
  }

  @Get('search')
  search(@Query() query: KoreaderRequestSearchDto, @CurrentUser() user: RequestUser) {
    return this.service.search(query, user);
  }

  @Get()
  list(@Query() query: KoreaderRequestPageDto, @CurrentUser() user: RequestUser) {
    return this.service.list(query.page, user, query.filter);
  }

  @Get('watch')
  watch(@Query() query: KoreaderRequestWatchDto, @CurrentUser() user: RequestUser) {
    return this.service.watch(query.ids.split(',').map(Number), user);
  }

  @Get(':id')
  get(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.service.get(id, user);
  }

  @Get(':id/releases')
  releases(@Param('id', ParseIntPipe) id: number, @Query() query: KoreaderReleasePageDto, @CurrentUser() user: RequestUser) {
    return this.service.releases(id, query.page, query.refresh === 'true', user);
  }

  @Post(':id/grab')
  @Auditable({
    action: AuditAction.BookRequestGrab,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Selected a book release from KOReader',
  })
  grab(@Param('id', ParseIntPipe) id: number, @Body() dto: KoreaderGrabReleaseDto, @CurrentUser() user: RequestUser) {
    return this.service.grab(id, dto.releaseId, user);
  }

  @Post(':id/discard-held')
  @Auditable({
    action: AuditAction.BookRequestImport,
    resource: AuditResource.BookRequest,
    description: 'Discarded a held import from KOReader to try another release',
  })
  discardHeld(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.service.discardHeld(id, user);
  }

  @Post('book/:bookId/replacement')
  @Auditable({
    action: AuditAction.BookRequestCreate,
    resource: AuditResource.BookRequest,
    description: 'Requested a library file replacement from KOReader',
  })
  replaceBook(@Param('bookId', ParseIntPipe) bookId: number, @Body() dto: KoreaderReplacementDto, @CurrentUser() user: RequestUser) {
    return this.service.replaceBook(bookId, dto.language, user);
  }

  @Post(':id/replacement')
  @Auditable({
    action: AuditAction.BookRequestCreate,
    resource: AuditResource.BookRequest,
    description: 'Requested a replacement edition from KOReader',
  })
  replace(@Param('id', ParseIntPipe) id: number, @Body() dto: KoreaderReplacementDto, @CurrentUser() user: RequestUser) {
    return this.service.replace(id, dto.language, user);
  }

  @Post()
  @Auditable({
    action: AuditAction.BookRequestCreate,
    resource: AuditResource.BookRequest,
    getResourceId: (_req, body) => (body as { request?: { id?: number } })?.request?.id,
    description: 'Requested a book from KOReader',
  })
  create(@Body() dto: KoreaderCreateRequestDto, @CurrentUser() user: RequestUser) {
    return this.service.create(dto, user);
  }
  @Post(':id/cancel')
  cancel(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.service.cancel(id, user);
  }
  @Post(':id/retry')
  retry(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.service.retry(id, user);
  }
}
