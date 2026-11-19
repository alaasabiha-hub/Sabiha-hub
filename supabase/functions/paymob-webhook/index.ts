import {config,json,rpc,verify,type Env} from '../paymob-sandbox/payment.ts';
export function handler(env:Env,fetcher=fetch){return async(req:Request)=>{
 if(req.method!=='POST')return json({error:'POST required'},405);
 try{
 const cfg=config(env); const secret=env('PAYMOB_HMAC_SECRET'); if(!secret)throw Error('HMAC not configured');
 const raw=await req.text(); if(raw.length>65536)return json({error:'Payload too large'},413);
 const obj=JSON.parse(raw).obj; const signature=new URL(req.url).searchParams.get('hmac')??'';
 if(!obj||!await verify(obj,signature,secret))return json({error:'Invalid signature'},401);
 if(String(obj.integration_id)!==cfg.integration)return json({error:'Wrong integration'},403);
 if(!Number.isSafeInteger(obj.amount_cents)||obj.amount_cents<=0||obj.currency!=='EGP')return json({error:'Invalid amount or currency'},400);
 const status=obj.is_refunded===true?'refund_reported':obj.is_voided===true?'void_reported':obj.pending===true?'pending':obj.success===true&&obj.error_occured===false&&obj.is_auth===false&&(obj.is_capture===true||obj.is_standalone_payment===true)?'sandbox_succeeded':'failed';
 await rpc(env,'accept_paymob_sandbox_callback',{p_order:String(obj.order.id),p_transaction:String(obj.id),p_amount:obj.amount_cents,p_currency:obj.currency,p_status:status,p_digest:signature.toLowerCase()},undefined,fetcher);
 return json({received:true});
 }catch{return json({error:'Callback rejected'},400);}
};}
if(import.meta.main)Deno.serve(handler(Deno.env.get));
