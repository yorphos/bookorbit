import { Inject, Injectable, ConflictException, NotFoundException } from '@nestjs/common';
import { and, eq, like, desc, sql, inArray } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { createHash } from 'node:crypto';
import { bookRequestWorkKey } from '@bookorbit/types';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { RouletteBookDto, RouletteDecisionDto, RouletteTasteDto } from './dto/koreader-roulette.dto';
const PREFIX = 'roulette:';
const TABLE = schema.userPreferences;
export type RouletteRecord = { book: RouletteBookDto; decision: string; version: string; key: string };
export function rouletteKey(book: { title: string; authors?: string[] }) {
  return createHash('sha256')
    .update(bookRequestWorkKey(book.title, book.authors?.[0], 'ebook'))
    .digest('hex')
    .slice(0, 32);
}
@Injectable()
export class KoreaderRouletteRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}
  async records(userId: number, limit = 500) {
    const rows = await this.db
      .select()
      .from(TABLE)
      .where(and(eq(TABLE.userId, userId), like(TABLE.category, PREFIX + 'book:%')))
      .orderBy(desc(TABLE.updatedAt))
      .limit(limit);
    return rows.map((row) => row.data as RouletteRecord);
  }
  async excluded(userId: number, keys: string[]) {
    if (!keys.length) return new Set<string>();
    const rows = await this.db
      .select()
      .from(TABLE)
      .where(
        and(
          eq(TABLE.userId, userId),
          inArray(
            TABLE.category,
            keys.map((key) => PREFIX + 'book:' + key),
          ),
        ),
      );
    return new Set(
      rows.filter((row) => ['match', 'pass'].includes((row.data as RouletteRecord).decision)).map((row) => (row.data as RouletteRecord).key),
    );
  }
  async matches(userId: number, page: number, q = '', genre = '', sort = 'recent') {
    const rows = await this.db
      .select()
      .from(TABLE)
      .where(
        and(
          eq(TABLE.userId, userId),
          like(TABLE.category, PREFIX + 'book:%'),
          sql`${TABLE.data}->>'decision' = 'match'`,
          q
            ? sql`strpos(lower(${TABLE.data}->'book'->>'title' || ' ' || coalesce(${TABLE.data}->'book'->>'authors','')),lower(${q})) > 0`
            : undefined,
          genre ? sql`${TABLE.data}->'book'->'genres' @> ${JSON.stringify([genre])}::jsonb` : undefined,
        ),
      )
      .orderBy(
        sort === 'title'
          ? sql`${TABLE.data}->'book'->>'title'`
          : sort === 'author'
            ? sql`${TABLE.data}->'book'->'authors'->>0`
            : desc(TABLE.updatedAt),
        desc(TABLE.category),
      )
      .limit(21)
      .offset((page - 1) * 20);
    return { items: rows.slice(0, 20).map((row) => row.data as RouletteRecord), hasMore: rows.length > 20 };
  }
  async get(userId: number, category: string) {
    const row = await this.db.query.userPreferences.findFirst({ where: and(eq(TABLE.userId, userId), eq(TABLE.category, PREFIX + category)) });
    return row?.data;
  }
  async history(userId: number, page: number) {
    return this.db
      .select({ data: TABLE.data, at: TABLE.updatedAt })
      .from(TABLE)
      .where(and(eq(TABLE.userId, userId), like(TABLE.category, PREFIX + 'event:%')))
      .orderBy(desc(TABLE.updatedAt))
      .limit(20)
      .offset((page - 1) * 20);
  }
  async decide(userId: number, input: RouletteDecisionDto) {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(83024,${userId})`);
      const eventCategory = PREFIX + 'event:' + input.eventId;
      const priorEvent = await tx.query.userPreferences.findFirst({ where: and(eq(TABLE.userId, userId), eq(TABLE.category, eventCategory)) });
      const key = input.decision === 'remove' && input.key ? input.key : rouletteKey(input.book);
      if (priorEvent) {
        const e = priorEvent.data as { key: string; decision: string; undone: boolean };
        if (e.key !== key || e.decision !== input.decision) throw new ConflictException('Decision id already used');
        return { eventId: input.eventId, key, undone: e.undone };
      }
      const category = PREFIX + 'book:' + key;
      const previous = await tx.query.userPreferences.findFirst({ where: and(eq(TABLE.userId, userId), eq(TABLE.category, category)) });
      const before = previous?.data as RouletteRecord | undefined;
      if (input.decision === 'skip' && before && ['match', 'pass'].includes(before.decision))
        throw new ConflictException('This book already has a decision. Undo it first.');
      if (input.decision === 'remove' && before?.decision !== 'match') throw new NotFoundException('Match not found');
      const data: RouletteRecord = {
        key,
        book: input.decision === 'remove' ? before!.book : input.book,
        decision: input.decision,
        version: input.eventId,
      };
      await tx
        .insert(TABLE)
        .values({ userId, category, data })
        .onConflictDoUpdate({ target: [TABLE.userId, TABLE.category], set: { data, updatedAt: new Date() } });
      await tx.insert(TABLE).values({
        userId,
        category: eventCategory,
        data: { key, decision: input.decision, before: before ?? null, after: data, eventId: input.eventId, undone: false },
      });
      return { key, eventId: input.eventId };
    });
  }
  async undo(userId: number, eventId: string) {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(83024,${userId})`);
      const where = and(eq(TABLE.userId, userId), eq(TABLE.category, PREFIX + 'event:' + eventId));
      const row = await tx.query.userPreferences.findFirst({ where });
      if (!row) throw new NotFoundException('Decision not found');
      const event = row.data as { key: string; before: RouletteRecord | null; undone: boolean };
      if (event.undone) return { undone: true };
      const bookWhere = and(eq(TABLE.userId, userId), eq(TABLE.category, PREFIX + 'book:' + event.key));
      const current = await tx.query.userPreferences.findFirst({ where: bookWhere });
      if ((current?.data as RouletteRecord)?.version !== eventId) throw new ConflictException('A newer decision exists. Undo that decision first.');
      if (event.before) await tx.update(TABLE).set({ data: event.before, updatedAt: new Date() }).where(bookWhere);
      else await tx.delete(TABLE).where(bookWhere);
      await tx
        .update(TABLE)
        .set({ data: { ...event, undone: true } })
        .where(where);
      return { undone: true };
    });
  }
  async tastes(userId: number, data: RouletteTasteDto) {
    await this.db
      .insert(TABLE)
      .values({ userId, category: PREFIX + 'tastes', data: { ...data } })
      .onConflictDoUpdate({ target: [TABLE.userId, TABLE.category], set: { data: { ...data }, updatedAt: new Date() } });
    return data;
  }
  async reset(userId: number) {
    await this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(83024,${userId})`);
      await tx.delete(TABLE).where(and(eq(TABLE.userId, userId), like(TABLE.category, PREFIX + '%')));
    });
    return { reset: true };
  }
}
