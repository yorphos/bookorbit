import { Body, Controller, Get, Post, Query, UseGuards, UseInterceptors } from '@nestjs/common';
import { KoreaderEtagInterceptor } from './koreader-etag.interceptor';
import { Public } from '../../common/decorators/public.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRouletteService } from './koreader-roulette.service';
import {
  RouletteAcquireDto,
  RouletteDecisionDto,
  RouletteQueryDto,
  RouletteQueueDto,
  RouletteResetDto,
  RouletteTasteDto,
  RouletteUndoDto,
} from './dto/koreader-roulette.dto';
@Public()
@UseGuards(KoreaderAuthGuard)
@UseInterceptors(KoreaderEtagInterceptor)
@Controller('koreader/plugin/roulette')
export class KoreaderRouletteController {
  constructor(private readonly service: KoreaderRouletteService) {}
  @Get() queue(@CurrentUser() user: RequestUser, @Query() query: RouletteQueueDto) {
    return this.service.queue(user, query);
  }
  @Get('matches') matches(@CurrentUser() user: RequestUser, @Query() query: RouletteQueryDto) {
    return this.service.matches(user, query);
  }
  @Post('decision') decision(@CurrentUser() user: RequestUser, @Body() body: RouletteDecisionDto) {
    return this.service.decide(user, body);
  }
  @Post('undo') undo(@CurrentUser() user: RequestUser, @Body() body: RouletteUndoDto) {
    return this.service.undo(user, body.eventId);
  }
  @Get('history') history(@CurrentUser() user: RequestUser, @Query() query: RouletteQueryDto) {
    return this.service.history(user, query.page);
  }
  @Get('tastes') tastes(@CurrentUser() user: RequestUser) {
    return this.service.tastes(user);
  }
  @Post('tastes') setTastes(@CurrentUser() user: RequestUser, @Body() body: RouletteTasteDto) {
    return this.service.tastes(user, body);
  }
  @Post('reset') reset(@CurrentUser() user: RequestUser, @Body() _body: RouletteResetDto) {
    void _body;
    return this.service.reset(user);
  }
  @Post('acquire') acquire(@CurrentUser() user: RequestUser, @Body() body: RouletteAcquireDto) {
    return this.service.acquire(user, body.keys);
  }
}
