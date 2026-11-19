import {handle} from './handler.ts';
Deno.serve((req)=>handle(req,(key)=>Deno.env.get(key)));
