import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, gte, inArray, like, ne, sql } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';

const PREFS = schema.userPreferences;
const STATUS = schema.userBookStatus;
export const SOCIAL_CATEGORY = 'koreader-social';
export const RECOMMEND_PREFIX = 'koreader-recommend:';

export type SocialSettings = { share: boolean; since?: string };
export type SocialRecommendation = { bookId: number; note?: string; at: string };

/**
 * Reads for the Kobo's opt-in "Friends" screen. Only readers who switched sharing on
 * are ever returned, and only the reading states and recommendations they made.
 */
@Injectable()
export class KoreaderSocialRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  /** Active readers other than `viewerId` who chose to share with the server's other readers. */
  async sharers(viewerId: number, limit = 50) {
    return this.db
      .select({ userId: PREFS.userId, name: schema.users.name, username: schema.users.username })
      .from(PREFS)
      .innerJoin(schema.users, eq(schema.users.id, PREFS.userId))
      .where(
        and(
          eq(PREFS.category, SOCIAL_CATEGORY),
          sql`(${PREFS.data}->>'share')::boolean = true`,
          ne(PREFS.userId, viewerId),
          eq(schema.users.active, true),
        ),
      )
      .orderBy(desc(PREFS.updatedAt))
      .limit(limit);
  }

  /** Reading, re-reading and finished books of these readers, newest first. */
  async activity(userIds: number[], since: Date, limit = 80) {
    if (!userIds.length) return [];
    return this.db
      .select({ userId: STATUS.userId, bookId: STATUS.bookId, status: STATUS.status, updatedAt: STATUS.updatedAt, finishedAt: STATUS.finishedAt })
      .from(STATUS)
      .where(and(inArray(STATUS.userId, userIds), inArray(STATUS.status, ['reading', 'rereading', 'read']), gte(STATUS.updatedAt, since)))
      .orderBy(desc(STATUS.updatedAt))
      .limit(limit);
  }

  /** Books these readers recommended from their Kobo, newest first. */
  async recommendations(userIds: number[], limit = 40) {
    if (!userIds.length) return [];
    const rows = await this.db
      .select({ userId: PREFS.userId, data: PREFS.data, updatedAt: PREFS.updatedAt })
      .from(PREFS)
      .where(and(inArray(PREFS.userId, userIds), like(PREFS.category, RECOMMEND_PREFIX + '%')))
      .orderBy(desc(PREFS.updatedAt))
      .limit(limit);
    return rows.map((row) => ({ userId: row.userId, ...(row.data as SocialRecommendation) }));
  }
}
