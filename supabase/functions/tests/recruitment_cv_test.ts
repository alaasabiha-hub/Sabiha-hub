import {handle,sha} from '../recruitment-cv/handler.ts';
const assert=(v:unknown,message='assertion failed')=>{if(!v)throw Error(message);};
const app='11111111-1111-4111-8111-111111111111',token='a'.repeat(64),pdf=new TextEncoder().encode('%PDF-1.4\nSynthetic CV fixture only\n%%EOF\n');
const env=(key:string)=>({SUPABASE_URL:'http://kong:8000',SUPABASE_SERVICE_ROLE_KEY:'local-service',SUPABASE_ANON_KEY:'local-anon'}[key]);
const upload=(bytes:Uint8Array=pdf,headers:Record<string,string>={})=>new Request('http://local/recruitment-cv',{method:'POST',headers:{'Content-Type':'application/pdf','x-application-id':app,'x-upload-token':token,...headers},body:new Uint8Array(bytes).buffer});
Deno.test('reject MIME, magic, token and streaming size before storage',async()=>{
 let calls=0;const fetcher=(async()=>{calls++;throw Error('unexpected storage');}) as typeof fetch;
 for(const req of [upload(pdf,{'Content-Type':'image/png'}),upload(new TextEncoder().encode('not a PDF attachment')),upload(pdf,{'x-upload-token':'wrong'}),upload(new Uint8Array(2097153))]){assert((await handle(req,env,fetcher)).status>=400);}
 assert(calls===0);
});
Deno.test('capability upload stores only private immutable PDF and finalizes unscanned',async()=>{
 const hash=await sha(pdf);const calls:string[]=[];
 const fetcher=(async(url:RequestInfo|URL,options?:RequestInit)=>{const u=String(url);calls.push(u);if(u.endsWith('/claim_recruitment_cv')){const body=JSON.parse(String(options?.body));assert(body.p_capability_hash===await sha(new TextEncoder().encode(token)));return Response.json({path:`${app}/${hash}.pdf`,state:'uploading'});}
 if(u.includes('/storage/v1/object/')){assert((options?.headers as Record<string,string>)['x-upsert']==='false');assert(options?.body instanceof Uint8Array);return Response.json({Key:'private'});}
 return Response.json({state:'quarantined_unscanned'});}) as typeof fetch;
 const result=await handle(upload(),env,fetcher);assert(result.status===200);assert((await result.json()).state==='quarantined_unscanned');assert(calls.length===3);assert(calls.every(c=>!c.includes(token)));
});
Deno.test('completed upload replay does not overwrite storage',async()=>{
 let calls=0;const hash=await sha(pdf);const fetcher=(async()=>{calls++;return Response.json({path:`${app}/${hash}.pdf`,state:'quarantined_unscanned'});}) as typeof fetch;
 assert((await handle(upload(),env,fetcher)).status===200);assert(calls===1);
});
Deno.test('owner signed download uses owner JWT authorization and browser-safe relative path',async()=>{
 const hash=await sha(pdf);let calls=0;const fetcher=(async(url:RequestInfo|URL,options?:RequestInit)=>{calls++;if(String(url).includes('/rpc/')){assert((options?.headers as Record<string,string>).Authorization==='Bearer owner-token');return Response.json({path:`${app}/${hash}.pdf`,state:'quarantined_unscanned'});}assert(JSON.parse(String(options?.body)).expiresIn===60);return Response.json({signedURL:`/object/sign/recruitment-cv-quarantine/${app}/${hash}.pdf?token=test-signature`});}) as typeof fetch;
 const r=await handle(new Request('http://local',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer owner-token'},body:JSON.stringify({action:'download',application_id:app})}),env,fetcher);
 const data=await r.json();assert(r.status===200);assert(data.signed_path.startsWith('/object/sign/recruitment-cv-quarantine/'));assert(!data.signed_path.includes('kong'));assert(data.signed_path.includes('download=CV-unscanned.pdf'));assert(data.state==='quarantined_unscanned');assert(calls===2);
});
Deno.test('non-owner cannot obtain storage signature',async()=>{
 let calls=0;const fetcher=(async()=>{calls++;return Response.json({error:'owner required'},{status:403});}) as typeof fetch;
 const r=await handle(new Request('http://local',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer employee-token'},body:JSON.stringify({action:'download',application_id:app})}),env,fetcher);assert(r.status===400);assert(calls===1);
});
