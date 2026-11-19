begin;

-- Cover foreign-key lookups and the public class-price join while keeping
-- direct table access revoked and RLS enabled.
create index if not exists business_service_vehicle_prices_class_code
  on private.business_service_vehicle_prices(class_code);
create index if not exists business_service_vehicle_prices_updated_by
  on private.business_service_vehicle_prices(updated_by);

commit;
