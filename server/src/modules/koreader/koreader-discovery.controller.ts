import { KoreaderCoverQueryDto } from './dto/koreader-discovery.dto';
import type { FastifyReply } from 'fastify';
import { KoreaderRequestPageDto } from './dto/koreader-requests.dto';
import { KoreaderBrowseQueryDto, KoreaderWorkParamsDto, KoreaderBulkRequestsDto } from './dto/koreader-discovery.dto';
import { Body, Controller, Get, Param, Post, Query, Res, UseGuards, UseInterceptors } from '@nestjs/common';
import { KoreaderEtagInterceptor } from './koreader-etag.interceptor';
import { Permission } from '@bookorbit/types';
import { Public } from '../../common/decorators/public.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderDiscoveryService } from './koreader-discovery.service';
import { KoreaderDiscoveryQueryDto } from './dto/koreader-discovery.dto';

@Public()
@UseGuards(KoreaderAuthGuard)
@RequirePermission(Permission.BookRequestAccess)
@UseInterceptors(KoreaderEtagInterceptor)
@Controller('koreader/plugin/discovery')
export class KoreaderDiscoveryController {
  constructor(private readonly discovery: KoreaderDiscoveryService) {}
  @Get('search')
  search(@Query() query: KoreaderDiscoveryQueryDto, @CurrentUser() user: RequestUser) {
    return this.discovery.search(query, user);
  }
  @Get('browse')
  browse(@Query() query: KoreaderBrowseQueryDto, @CurrentUser() user: RequestUser) {
    return this.discovery.browse(query, user);
  }
  @Get('series')
  series(@Query() query: KoreaderBrowseQueryDto, @CurrentUser() user: RequestUser) {
    return this.discovery.series(query, user);
  }
  @Post('requests')
  requestMany(@Body() dto: KoreaderBulkRequestsDto, @CurrentUser() user: RequestUser) {
    return this.discovery.requestMany(dto, user);
  }
  @Get('cover')
  async remoteCover(@Query() query: KoreaderCoverQueryDto, @CurrentUser() user: RequestUser, @Res() response: FastifyReply) {
    const bytes = await this.discovery.coverUrl(query.url, user);
    return response.headers({ 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=86400' }).send(bytes);
  }
  @Get('works/:id')
  work(@Param() params: KoreaderWorkParamsDto, @Query() query: KoreaderRequestPageDto, @CurrentUser() user: RequestUser) {
    return this.discovery.work(params.id, query.page, user);
  }
  @Get('works/:id/cover')
  async cover(@Param() params: KoreaderWorkParamsDto, @CurrentUser() user: RequestUser, @Res() response: FastifyReply) {
    const bytes = await this.discovery.cover(params.id, user);
    return response.headers({ 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=86400' }).send(bytes);
  }
}
