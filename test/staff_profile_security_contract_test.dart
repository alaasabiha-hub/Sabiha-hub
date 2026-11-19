import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'supabase/migrations/20261119160000_staff_self_profile_edit.sql',
  ).readAsStringSync().toLowerCase();
  final policyMigration = File(
    'supabase/migrations/20261119161000_staff_profile_avatar_policy_session_safe.sql',
  ).readAsStringSync().toLowerCase();

  test('self profile APIs require the current authenticated staff account', () {
    expect(migration, contains('uid is null'));
    expect(migration, contains('where user_id=uid and is_active'));
    expect(
      migration,
      contains(
        'grant execute on function public.get_my_staff_profile() to authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.save_my_staff_profile(text,text) to authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on function public.save_my_staff_profile(text,text) from public, anon',
      ),
    );
  });

  test(
    'profile editing cannot write role, permissions, or branch membership',
    () {
      expect(
        migration,
        contains(
          'update public.staff_profiles set full_name=new_name where user_id=uid and is_active',
        ),
      );
      expect(
        migration,
        isNot(contains('update public.staff_profiles set role')),
      );
      expect(
        migration,
        isNot(contains('update public.staff_profiles set permissions')),
      );
      expect(migration, isNot(contains('update public.staff_branch_access')));
    },
  );

  test('private avatar storage is non-public and restricted to own folder', () {
    expect(
      migration,
      contains(
        "values ('staff-profile-avatars', 'staff-profile-avatars', false",
      ),
    );
    expect(
      migration,
      contains("split_part(name, '/', 1) = (select auth.uid())::text"),
    );
    expect(
      policyMigration,
      contains('staff read own or owner profile avatars'),
    );
    expect(
      policyMigration,
      contains('staff delete own private profile avatar'),
    );
    expect(
      policyMigration,
      contains('private.can_access_staff_profile_avatar(name,\'read\')'),
    );
  });

  test(
    'public employee photo proposal remains unpublished pending approval',
    () {
      expect(
        migration,
        contains('insert into public.employee_public_profiles'),
      );
      expect(migration, contains('false, true)'));
      expect(
        migration,
        contains('set pending_photo_path=p_path, photo_consent=true'),
      );
      expect(
        migration,
        contains(
          'grant execute on function public.propose_employee_photo(text,boolean) to authenticated',
        ),
      );
      expect(
        policyMigration,
        contains('insert into public.employee_public_profiles'),
      );
      expect(policyMigration, isNot(contains('private.active_staff_role()')));
    },
  );
}
