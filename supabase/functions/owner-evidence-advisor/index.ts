import { handler } from "./handler.ts";
Deno.serve(handler(Deno.env.get));
