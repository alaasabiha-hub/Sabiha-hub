# Owner catalogue concurrency — source-only acceptance harness

tools/fleet_catalogue_concurrency.py is PLAN by default. It has not connected to DB/Auth or performed mutations. Root reviews/backups/releases the local DB before action run. Applied migration32036 is untouched. No Flutter, browser or build is involved.

The run uses the actual existing owner and a real unexpired persisted session in two authenticated database sessions. It creates one new tagged QA party with explicitly unknown legal registration/tax/address/representative data, one actual new QA catalogue vehicle and one blocked vehicle attempt. These are catalogue test records, not performed work or company/legal verification. No Auth creation/sign-in/phone/role/HR/financial/ETA/gate change exists.

All entity/command/cleanup UUIDs, QA terms and full preexisting public/private/Auth row hashes plus document counters/financial row counts are journaled0600 before the first prepare. Request/entity collisions are rejected in readonly preflight. The harness never regenerates a journaled operation after an unknown response; an existing journal permits cleanup only, not repeated accepted races.

Seven distinct actual waits are observed using pg_blocking_pids:
1. Same prepared create command applied concurrently: one party/version event, identical returned receipt.
2. Two distinct edits expecting party version1: one actual winner, waiting edit gets40001.
3. Parent archive commits first: waiting prepared new car rejects55000 and creates no vehicle.
4. New car commits first: waiting archive succeeds; vehicle remains historically recorded but effectively inactive.
5. Two distinct vehicle edits expecting version1: one actual winner, waiting edit gets40001.
6. Unknown request close commits first: waiting delayed prepare stays closed with no entity.
7. Prepared command commits first: waiting close seals it; later apply stays closed with no entity.

Finally, owned sessions roll back/close; all producer command nonces are authoritatively closed first so delayed applies settle or are fenced. Cleanup recognizes only the new party/vehicle IDs with their exact creation-command event/owner witnesses. It archives new children and parent using the actual prepared APIs and current expected versions, then closes the planned cleanup references. No DELETE, direct row correction, old company edit or fabricated historical version occurs. QA rows/audit remain archived.

The proof requires all seven cases, every old public/private/Auth/HR row unchanged, financial/Auth counts and document counters unchanged, exactly the one planned party created (two fenced parties absent), no active QA child and parent archived. Errors persist only sanitized types and UUID/control metadata; they stop rather than claiming partial success. There is no backend/overall concurrency acceptance until root actually executes the tool and reviews preservation/cleanup evidence.
