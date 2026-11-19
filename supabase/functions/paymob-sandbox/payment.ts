export const fields = 'amount_cents created_at currency error_occured has_parent_transaction id integration_id is_3d_secure is_auth is_capture is_refunded is_standalone_payment is_voided order.id owner pending source_data.pan source_data.sub_type source_data.type success'.split(' ');
export function canonical(obj: Record<string, unknown>): string {
 return fields.map(path => { let v: unknown = obj; for (const k of path.split('.')) v = (v as Record<string, unknown>)?.[k]; if (!['string','boolean','number'].includes(typeof v)) throw Error('Missing signed field'); return String(v); }).join('');
}
export async function digest(obj: Record<string, unknown>, secret: string) {
 const key = await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-512'},false,['sign']);
 return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(canonical(obj)))),b=>b.toString(16).padStart(2,'0')).join('');
}
export async function verify(obj: Record<string, unknown>, signature: string, secret: string) {
 if (!/^[a-f0-9]{128}$/i.test(signature)) return false;
 const expected = await digest(obj,secret); let difference=0; for(let i=0;i<128;i++) difference |= expected.charCodeAt(i)^signature.toLowerCase().charCodeAt(i); return difference===0;
}
export type Env = (name:string)=>string|undefined;
export function config(env:Env) {
 const secret=env('PAYMOB_SECRET_KEY')??'';
 if(env('PAYMOB_MODE')!=='sandbox'||!/^egy_sk_test_[A-Za-z0-9_-]+$/.test(secret)) throw Error('Sandbox test credentials required');
 const integration=env('PAYMOB_SANDBOX_INTEGRATION_ID')??'';
 if(!/^\d+$/.test(integration)) throw Error('Sandbox integration required');
 return {secret,integration};
}
export const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
export async function rpc(env:Env,name:string,args:unknown,jwt?:string,fetcher=fetch){
 const service=env('SUPABASE_SERVICE_ROLE_KEY')??''; const response=await fetcher(`${env('SUPABASE_URL')}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:jwt?(env('SUPABASE_ANON_KEY')??''):service,Authorization:`Bearer ${jwt??service}`,'Content-Type':'application/json'},body:JSON.stringify(args)});
 if(!response.ok) throw Error('Database request failed'); const text=await response.text(); return text?JSON.parse(text):null;
}
