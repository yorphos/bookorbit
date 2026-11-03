import { createHash } from 'node:crypto';
import { type CallHandler, type ExecutionContext, Injectable, type NestInterceptor } from '@nestjs/common';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { map, type Observable } from 'rxjs';

// Fields that change on every response without the content changing.
const VOLATILE = new Set(['generatedAt']);

/** A weak entity tag for a JSON body, ignoring per-response timestamps. */
export function koreaderEtag(body: unknown): string {
  const json = JSON.stringify(body, (key, value: unknown) => (VOLATILE.has(key) ? undefined : value));
  return (
    'W/"' +
    createHash('sha1')
      .update(json ?? '')
      .digest('base64url') +
    '"'
  );
}

export function etagMatches(header: string | string[] | undefined, tag: string): boolean {
  if (!header) return false;
  const values = Array.isArray(header) ? header : header.split(',');
  return values.some((value) => {
    const candidate = value.trim();
    return candidate === '*' || candidate === tag || 'W/' + candidate === tag;
  });
}

/**
 * Lets a Kobo ask "has this changed?" for its JSON screens: a GET answers with an
 * ETag, and a repeat GET that sends it back as If-None-Match gets an empty 304.
 * The device then keeps the copy it has and skips an e-ink repaint.
 * Handlers that write the reply themselves (covers, files) are left alone.
 */
@Injectable()
export class KoreaderEtagInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const http = context.switchToHttp();
    const request = http.getRequest<FastifyRequest>();
    const reply = http.getResponse<FastifyReply>();
    if (request.method !== 'GET') return next.handle();
    return next.handle().pipe(
      map((body: unknown) => {
        if (body === undefined || body === null || reply.sent || typeof body !== 'object') return body;
        const tag = koreaderEtag(body);
        reply.header('ETag', tag);
        reply.header('Cache-Control', 'private, no-cache');
        if (etagMatches(request.headers['if-none-match'], tag)) {
          reply.status(304);
          return '';
        }
        return body;
      }),
    );
  }
}
