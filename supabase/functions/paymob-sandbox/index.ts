import {config,json,rpc,type Env} from './payment.ts';
export function handler(env:Env,fetcher=fetch){return async(req:Request)=>{
 const origin=req.headers.get('Origin');const allowed=(env('PAYMOB_APP_ORIGIN')??env('APP_ORIGIN')??'').split(',').map(x=>x.trim()).filter(Boolean);
 if(origin&&!allowed.includes(origin))return json({error:'Origin rejected'},403);
 const reply=(value:unknown,status=200)=>{const response=json(value,status);if(origin){response.headers.set('Access-Control-Allow-Origin',origin);response.headers.set('Vary','Origin');}return response;};
 if(req.method==='OPTIONS'){const response=reply(null);const empty=new Response(null,{status:204,headers:response.headers});empty.headers.set('Access-Control-Allow-Methods','POST, OPTIONS');empty.headers.set('Access-Control-Allow-Headers','authorization, apikey, content-type, x-client-info');return empty;}
 if(req.method!=='POST')return reply({error:'POST required'},405);
 let intent:string|undefined;let attempted=false;
 try{
 const cfg=config(env);
 const trustedUrl=(key:string)=>{const value=env(key);if(!value)throw Error('Server callback URL required');const url=new URL(value);if(url.protocol!=='https:'||url.username||url.password||url.hash||!url.hostname.includes('.')||url.hostname.endsWith('.local')||url.hostname.endsWith('.internal')||url.hostname==='localhost'||url.hostname.endsWith('.localhost')||/^\d+(\.\d+){3}$/.test(url.hostname)||url.hostname.includes(':'))throw Error('Public HTTPS callback URL required');return url.href;};
 const notification=trustedUrl('PAYMOB_NOTIFICATION_URL');const redirection=trustedUrl('PAYMOB_REDIRECTION_URL');const jwt=req.headers.get('Authorization')?.match(/^Bearer (.+)$/)?.[1];if(!jwt)return reply({error:'Authentication required'},401);
 const user=await fetcher(`${env('SUPABASE_URL')}/auth/v1/user`,{headers:{apikey:env('SUPABASE_ANON_KEY')??'',Authorization:`Bearer ${jwt}`}});if(!user.ok)return reply({error:'Authentication required'},401);
 const b=await req.json();if(!/^[0-9a-f-]{36}$/i.test(b.request_id)||typeof b.invoice_id!=='string'||!b.invoice_id||b.invoice_id.length>200)return reply({error:'Invalid request'},400);
 const keys=['first_name','last_name','email','phone_number','country','city','street','building','floor','apartment'];const billing=b.billing_data;
 if(!billing||keys.some(k=>typeof billing[k]!=='string'||!billing[k].trim()||billing[k].length>200))return reply({error:'Real billing_data required: '+keys.join(', ')},400);
 const pk=env('PAYMOB_PUBLIC_KEY')??'';if(!/^egy_pk_test_[A-Za-z0-9_-]+$/.test(pk))throw Error('Sandbox public key required');
 const r=await rpc(env,'reserve_paymob_sandbox',{p_request:b.request_id,p_invoice:b.invoice_id},jwt,fetcher);
 if(!r.claimed)return reply({status:r.status,checkout_url:r.checkout_url??null});intent=r.intent_id;
 if(!Number.isSafeInteger(r.amount_cents)||r.amount_cents<=0||r.currency!=='EGP')throw Error('Invalid invoice');
 attempted=true;const response=await fetcher('https://accept.paymob.com/v1/intention/',{method:'POST',headers:{Authorization:`Token ${cfg.secret}`,'Content-Type':'application/json'},body:JSON.stringify({amount:r.amount_cents,currency:'EGP',payment_methods:[Number(cfg.integration)],billing_data:Object.fromEntries(keys.map(k=>[k,billing[k].trim()])),special_reference:intent,notification_url:notification,redirection_url:redirection}),signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw Error('Provider failure');const d=await response.json();if(!d.id||!d.client_secret||!d.intention_order_id)throw Error('Incomplete response');
 const url=new URL('https://accept.paymob.com/unifiedcheckout/');url.searchParams.set('publicKey',pk);url.searchParams.set('clientSecret',d.client_secret);
 await rpc(env,'attach_paymob_sandbox',{p_intent:intent,p_order:String(d.intention_order_id),p_provider_intent:String(d.id),p_checkout_url:url.href},undefined,fetcher);return reply({status:'pending',checkout_url:url.href});
 }catch{if(intent)try{await rpc(env,'fail_paymob_sandbox',{p_intent:intent,p_uncertain:attempted},undefined,fetcher);}catch{/* Never resend uncertain requests. */}return reply({error:'Sandbox checkout unavailable'},503);}
};}
if(import.meta.main)Deno.serve(handler(Deno.env.get));
