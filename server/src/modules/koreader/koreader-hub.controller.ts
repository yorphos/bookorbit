import { Body, Controller, Delete, Get, HttpCode, Param, ParseIntPipe, Post, Query, UseGuards, UseInterceptors } from '@nestjs/common';
import { KoreaderEtagInterceptor } from './koreader-etag.interceptor';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderHubService } from './koreader-hub.service';
import {
  KoreaderCollectionBookDto,
  KoreaderCreateCollectionDto,
  KoreaderErrorReportDto,
  KoreaderNextQueryDto,
  KoreaderRecommendDto,
  KoreaderRecommendParamsDto,
  KoreaderSocialSharingDto,
  KoreaderCollectionQueryDto,
  KoreaderHubPageDto,
  KoreaderWishlistBookDto,
  KoreaderWishlistKeyDto,
} from './dto/koreader-hub.dto';

@Public()
@UseGuards(KoreaderAuthGuard)
@UseInterceptors(KoreaderEtagInterceptor)
@Controller('koreader/plugin/hub')
export class KoreaderHubController {
  constructor(private readonly hub: KoreaderHubService) {}

  @Get('home')
  home(@CurrentUser() user: RequestUser) {
    return this.hub.home(user);
  }

  @Get('discover')
  discover(@CurrentUser() user: RequestUser) {
    return this.hub.discovery(user);
  }

  @Get('genres')
  genres(@CurrentUser() user: RequestUser) {
    return this.hub.genres(user);
  }

  @Get('stats')
  stats(@CurrentUser() user: RequestUser) {
    return this.hub.stats(user);
  }

  @Get('next')
  next(@CurrentUser() user: RequestUser, @Query() query: KoreaderNextQueryDto) {
    return this.hub.next(user, query.bookId);
  }

  @Get('social')
  social(@CurrentUser() user: RequestUser) {
    return this.hub.socialFeed(user);
  }

  @Post('social/sharing')
  sharing(@CurrentUser() user: RequestUser, @Body() body: KoreaderSocialSharingDto) {
    return this.hub.setSocialSharing(user, body.share);
  }

  @Post('social/recommendations')
  recommend(@CurrentUser() user: RequestUser, @Body() body: KoreaderRecommendDto) {
    return this.hub.recommend(user, body.bookId, body.note);
  }

  @Delete('social/recommendations/:bookId')
  unrecommend(@CurrentUser() user: RequestUser, @Param() params: KoreaderRecommendParamsDto) {
    return this.hub.unrecommend(user, params.bookId);
  }

  @Post('error-reports')
  @HttpCode(202)
  reportError(@CurrentUser() user: RequestUser, @Body() body: KoreaderErrorReportDto) {
    return this.hub.reportError(user, body);
  }

  @Post('collections')
  createCollection(@CurrentUser() user: RequestUser, @Body() body: KoreaderCreateCollectionDto) {
    return this.hub.createCollection(user, body.name);
  }

  @Get('collections')
  collections(@CurrentUser() user: RequestUser, @Query() query: KoreaderCollectionQueryDto) {
    return this.hub.collectionList(user, query.page, query.bookId);
  }

  @Post('collections/:id/books')
  add(@CurrentUser() user: RequestUser, @Param('id', ParseIntPipe) id: number, @Body() body: KoreaderCollectionBookDto) {
    return this.hub.addToCollection(user, id, body.bookId);
  }

  @Delete('collections/:id/books/:bookId')
  remove(@CurrentUser() user: RequestUser, @Param('id', ParseIntPipe) id: number, @Param('bookId', ParseIntPipe) bookId: number) {
    return this.hub.removeFromCollection(user, id, bookId);
  }

  @Get('wishlist')
  wishlist(@CurrentUser() user: RequestUser, @Query() query: KoreaderHubPageDto) {
    return this.hub.wishlist(user, query.page);
  }

  @Post('wishlist')
  saveWishlist(@CurrentUser() user: RequestUser, @Body() book: KoreaderWishlistBookDto) {
    return this.hub.saveWishlist(user, book);
  }

  @Delete('wishlist/:key')
  removeWishlist(@CurrentUser() user: RequestUser, @Param() params: KoreaderWishlistKeyDto) {
    return this.hub.removeWishlist(user, params.key);
  }
}
