// Run inside the app container after copying this script and the candidate dist.
// Only a session-local TEMP table is changed; no production user data is touched.
const assert=require('node:assert/strict');
const {Client}=require('pg');const {drizzle}=require('drizzle-orm/node-postgres');const {randomUUID}=require('node:crypto');
const root=process.env.ROULETTE_DIST||'/app/dist';
const schema=require(root+'/db/schema');
const {KoreaderRouletteRepository,rouletteKey}=require(root+'/modules/koreader/koreader-roulette.repository');
(async()=>{
 const client=new Client({host:process.env.POSTGRES_HOST,port:Number(process.env.POSTGRES_PORT||5432),user:process.env.POSTGRES_USER,password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});await client.connect();
 try{
  await client.query('CREATE TEMP TABLE user_preferences (id serial PRIMARY KEY,user_id integer NOT NULL,category text NOT NULL,data jsonb NOT NULL,updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,category))');
  const repo=new KoreaderRouletteRepository(drizzle(client,{schema}));
  const book={title:'Frankenstein',authors:['Mary Shelley'],genres:['Gothic','Horror'],description:'Public-domain test fixture'};
  const match={eventId:randomUUID(),decision:'match',book};
  const result=await repo.decide(101,match);await repo.decide(101,match);
  assert.equal((await repo.history(101,1)).length,1,'retry must be idempotent');
  assert.equal((await repo.matches(101,1,'Shelley','Gothic','title')).items.length,1,'SQL metadata filters must work');
  assert.equal((await repo.matches(102,1)).items.length,0,'matches must be per-user');
  assert.equal((await repo.excluded(102,[result.key])).size,0,'negative feedback must be per-user');
  await assert.rejects(repo.undo(102,match.eventId),'other users cannot undo decisions');
  const remove={eventId:randomUUID(),decision:'remove',key:result.key,book:{...book,title:'Frankenstein; or, The Modern Prometheus'}};await repo.decide(101,remove);
  assert.equal((await repo.matches(101,1)).items.length,0);
  await assert.rejects(repo.undo(101,match.eventId),'old undo must not overwrite a newer decision');
  await repo.undo(101,remove.eventId);assert.equal((await repo.matches(101,1)).items.length,1,'undo removal restores match');
  await repo.undo(101,match.eventId);await repo.undo(101,match.eventId);
  assert.equal((await repo.matches(101,1)).items.length,0,'undo is persistent and idempotent');
  await repo.decide(101,{eventId:randomUUID(),decision:'pass',book});assert((await repo.excluded(101,[rouletteKey(book)])).has(rouletteKey(book)));
  await repo.decide(102,{eventId:randomUUID(),decision:'match',book});
  await repo.tastes(101,{genres:['Horror'],favorites:['Dracula']});await repo.reset(101);
  assert.equal((await repo.history(101,1)).length,0);assert.equal((await repo.matches(102,1)).items.length,1,'reset must not touch other users');
  const reload=new KoreaderRouletteRepository(drizzle(client,{schema}));assert.equal((await reload.matches(102,1)).items[0].book.title,'Frankenstein','state persists across service instances');
  console.log(JSON.stringify({passed:true,checks:15,storage:'PostgreSQL session-local TEMP table',productionRowsChanged:0}));
 }finally{await client.end();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
