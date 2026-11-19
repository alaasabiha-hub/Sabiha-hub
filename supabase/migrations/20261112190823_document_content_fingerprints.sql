-- Local prepared change; existing documents remain untouched until explicitly fingerprinted.
alter table public.business_documents add column content_sha256 text
    check (content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$');
create unique index business_documents_content_sha256_uidx
    on public.business_documents(content_sha256) where content_sha256 is not null;
