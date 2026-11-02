import { Body, Controller, Delete, Get, Param, ParseIntPipe, Post, Query, UseGuards } from '@nestjs/common';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderHubService } from './koreader-hub.service';
import {
  KoreaderCollectionBookDto,
  KoreaderCollectionQueryDto,
  KoreaderHubPageDto,
  KoreaderWishlistBookDto,
  KoreaderWishlistKeyDto,
} from './dto/koreader-hub.dto';

@Public()
@UseGuards(KoreaderAuthGuard)
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
