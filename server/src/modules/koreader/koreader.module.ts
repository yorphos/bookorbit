import { CatalogModule } from '../catalog/catalog.module';
import { KoreaderRouletteController } from './koreader-roulette.controller';
import { KoreaderRouletteService } from './koreader-roulette.service';
import { KoreaderRouletteRepository } from './koreader-roulette.repository';
import { KoreaderExternalCatalogService } from './koreader-external-catalog.service';
import { KoreaderHubService } from './koreader-hub.service';
import { KoreaderCoverCacheService } from './koreader-cover-cache.service';
import { KoreaderSocialRepository } from './koreader-social.repository';
import { KoreaderHubController } from './koreader-hub.controller';
import { CollectionModule } from '../collection/collection.module';
import { UserPreferencesModule } from '../user-preferences/user-preferences.module';
import { KoreaderDiscoveryController } from './koreader-discovery.controller';
import { KoreaderDiscoveryService } from './koreader-discovery.service';
import { Module } from '@nestjs/common';

import { BookRequestModule } from '../book-request/book-request.module';
import { MetadataFetchModule } from '../metadata-fetch/metadata-fetch.module';
import { MetadataPreferencesModule } from '../metadata-preferences/metadata-preferences.module';
import { KoreaderRequestsController } from './koreader-requests.controller';
import { KoreaderRequestsService } from './koreader-requests.service';

import { CommonModule } from '../../common/common.module';
import { AchievementModule } from '../achievement/achievement.module';
import { AppSettingsModule } from '../app-settings/app-settings.module';
import { AnnotationModule } from '../annotation/annotation.module';
import { AuthorsModule } from '../authors/authors.module';
import { BookmarkModule } from '../bookmark/bookmark.module';
import { BookModule } from '../book/book.module';
import { BrowseCountsModule } from '../browse-counts/browse-counts.module';
import { DashboardModule } from '../dashboard/dashboard.module';
import { OpdsModule } from '../opds/opds.module';
import { PositionConverterModule } from '../position-converter/position-converter.module';
import { ReadingSessionModule } from '../reading-session/reading-session.module';
import { RecommendationModule } from '../recommendation/recommendation.module';
import { UserModule } from '../user/user.module';
import { UserBookNoteModule } from '../user-book-note/user-book-note.module';
import { UserBookStatusModule } from '../user-book-status/user-book-status.module';
import { KoreaderAnnotationExchangeService } from './koreader-annotation-exchange.service';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderBookmarkExchangeService } from './koreader-bookmark-exchange.service';
import { KoreaderBookmarkRepository } from './koreader-bookmark.repository';
import { KoreaderCatalogController } from './koreader-catalog.controller';
import { KoreaderCatalogService } from './koreader-catalog.service';
import { KoreaderPackageService } from './koreader-package.service';
import { KoreaderChapterExtractorService } from './koreader-chapter-extractor.service';
import { KoreaderChapterService } from './koreader-chapter.service';
import { KoreaderController } from './koreader.controller';
import { KoreaderHashLinkService } from './koreader-hash-link.service';
import { KoreaderPluginAnnotationService } from './koreader-plugin-annotation.service';
import { KoreaderPluginController } from './koreader-plugin.controller';
import { KoreaderPluginRepository } from './koreader-plugin.repository';
import { KoreaderPluginService } from './koreader-plugin.service';
import { KoreaderRepository } from './koreader.repository';
import { KoreaderDeliveryService } from './koreader-delivery.service';
import { KoreaderDeliveryController } from './koreader-delivery.controller';
import { KoreaderService } from './koreader.service';
import { KoreaderStatsService } from './koreader-stats.service';
import { KoreaderSyncEstimateCleanupService } from './koreader-sync-estimate-cleanup.service';

@Module({
  imports: [
    CatalogModule,
    CollectionModule,
    UserPreferencesModule,
    BookRequestModule,
    MetadataFetchModule,
    MetadataPreferencesModule,
    CommonModule,
    UserModule,
    UserBookNoteModule,
    UserBookStatusModule,
    AchievementModule,
    AppSettingsModule,
    AnnotationModule,
    AuthorsModule,
    BookModule,
    BookmarkModule,
    BrowseCountsModule,
    DashboardModule,
    OpdsModule,
    PositionConverterModule,
    ReadingSessionModule,
    RecommendationModule,
  ],
  controllers: [
    KoreaderRouletteController,
    KoreaderHubController,
    KoreaderDiscoveryController,
    KoreaderRequestsController,
    KoreaderDeliveryController,
    KoreaderController,
    KoreaderPluginController,
    KoreaderCatalogController,
  ],
  providers: [
    KoreaderRouletteService,
    KoreaderRouletteRepository,
    KoreaderHubService,
    KoreaderRequestsService,
    KoreaderDiscoveryService,
    KoreaderExternalCatalogService,
    KoreaderCoverCacheService,
    KoreaderSocialRepository,
    KoreaderDeliveryService,
    KoreaderService,
    KoreaderHashLinkService,
    KoreaderRepository,
    KoreaderAuthGuard,
    KoreaderCatalogService,
    KoreaderPackageService,
    KoreaderChapterService,
    KoreaderChapterExtractorService,
    KoreaderPluginService,
    KoreaderPluginRepository,
    KoreaderPluginAnnotationService,
    KoreaderAnnotationExchangeService,
    KoreaderBookmarkExchangeService,
    KoreaderBookmarkRepository,
    KoreaderStatsService,
    KoreaderSyncEstimateCleanupService,
  ],
  exports: [KoreaderService, KoreaderRepository],
})
export class KoreaderModule {}
