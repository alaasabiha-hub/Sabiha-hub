export type Env=(key:string)=>string|undefined;
const maxSize=2*1024*1024;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-application-id,x-upload-token','Access-Control-Allow-Methods':'POST,OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
export async function sha(bytes:Uint8Array){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(bytes).buffer))].map(v=>v.toString(16).padStart(2,'0')).join('');}
async function bounded(req:Request){
 const declared=req.headers.get('content-length');if(declared!==null&&(!/^\d+$/.test(declared)||Number(declared)>maxSize)){throw Error('size');}
 if(!req.body){throw Error('body');}const reader=req.body.getReader();const chunks:Uint8Array[]=[];let total=0;
 while(true){const {done,value}=await reader.read();if(done){break;}total+=value.length;if(total>maxSize){await reader.cancel();throw Error('size');}chunks.push(value);}
 const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}
export async function handle(req:Request,env:Env,fetcher:typeof fetch=fetch):Promise<Response>{
 if(req.method==='OPTIONS'){return new Response(null,{status:204,headers:cors});}if(req.method!=='POST'){return json({error:'POST required'},405);}
 const base=env('SUPABASE_URL')??'',service=env('SUPABASE_SERVICE_ROLE_KEY')??'',anon=env('SUPABASE_ANON_KEY')??'';
 if(!base||!service||!anon){return json({error:'Attachment service unavailable'},503);}
 const rpc=async(name:string,args:unknown,ownerJwt?:string)=>{
  const response=await fetcher(`${base}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:ownerJwt?anon:service,Authorization:ownerJwt?`Bearer ${ownerJwt}`:`Bearer ${service}`,'Content-Type':'application/json'},body:JSON.stringify(args)});
  if(!response.ok){throw Error('denied');}return await response.json();
 };
 try{
  const mime=(req.headers.get('content-type')??'').split(';')[0].trim().toLowerCase();
  if(mime==='application/json'){
   const raw=await bounded(req);if(raw.length>1000){return json({error:'Invalid download request'},400);}const body=JSON.parse(new TextDecoder().decode(raw));
   if(body.action!=='download'||!uuid.test(body.application_id??'')){return json({error:'Invalid download request'},400);}
   const auth=req.headers.get('authorization')??'';if(!auth.startsWith('Bearer ')||auth.length>8192){return json({error:'Owner authentication required'},401);}
   const object=await rpc('owner_recruitment_cv',{p_application:body.application_id},auth.slice(7));
   if(!object||object.state!=='quarantined_unscanned'||!new RegExp(`^${body.application_id}/[0-9a-f]{64}\\.pdf$`,'i').test(object.path)){return json({error:'Attachment unavailable'},404);}
   const signed=await fetcher(`${base}/storage/v1/object/sign/recruitment-cv-quarantine/${object.path}`,{method:'POST',headers:{apikey:service,Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:JSON.stringify({expiresIn:60})});
   if(!signed.ok){throw Error('storage');}const result=await signed.json();const url=new URL(result.signedURL,'https://storage.invalid');if(url.origin!=='https://storage.invalid'||url.pathname!==`/object/sign/recruitment-cv-quarantine/${object.path}`){throw Error('signed path');}url.searchParams.set('download','CV-unscanned.pdf');
   return json({signed_path:url.pathname+url.search,expires_in:60,state:'quarantined_unscanned',warning:'Untrusted PDF. Not malware scanned. Download attachment only; no preview or automatic processing.'});
  }
  if(mime!=='application/pdf'){return json({error:'PDF required'},415);}
  const app=req.headers.get('x-application-id')??'',token=req.headers.get('x-upload-token')??'';
  if(!uuid.test(app)||! /^[0-9a-f]{64}$/.test(token)){return json({error:'Invalid upload capability'},403);}
  const bytes=await bounded(req);const head=new TextDecoder().decode(bytes.subarray(0,9));const tail=new TextDecoder().decode(bytes.subarray(Math.max(0,bytes.length-1024)));
  if(bytes.length<16||!/^%PDF-[12]\.[0-9][\r\n ]/.test(head)||!tail.includes('%%EOF')){return json({error:'Valid PDF header and trailer required'},415);}
  const digest=await sha(bytes);const claim=await rpc('claim_recruitment_cv',{p_application:app,p_capability_hash:await sha(new TextEncoder().encode(token)),p_size:bytes.length,p_sha256:digest});
  if(claim.path!==`${app}/${digest}.pdf`){throw Error('path');}
  if(claim.state!=='quarantined_unscanned'){
   const uploaded=await fetcher(`${base}/storage/v1/object/recruitment-cv-quarantine/${claim.path}`,{method:'POST',headers:{apikey:service,Authorization:`Bearer ${service}`,'Content-Type':'application/pdf','x-upsert':'false'},body:bytes});
   if(!uploaded.ok&&uploaded.status!==409&&uploaded.status!==400){throw Error('storage');}
   await rpc('finalize_recruitment_cv',{p_application:app,p_sha256:digest});
  }
  return json({state:'quarantined_unscanned',sha256:digest,size_bytes:bytes.length});
 }catch(e){return json({error:e instanceof Error&&e.message==='size'?'PDF exceeds 2 MiB':'Attachment request rejected'},400);}
}
