import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';

/// A read-only view of everything in the backend, for the local admin
/// dashboard. Authenticates as a PocketBase **superuser** (separate from the
/// app's device identity) so it can see all collections — but location
/// contents remain end-to-end encrypted, so even here they're just ciphertext.
class AdminSnapshot {
  final List<RecordModel> users;
  final List<RecordModel> contacts;
  final List<RecordModel> shares;
  final List<RecordModel> pairs;
  AdminSnapshot(this.users, this.contacts, this.shares, this.pairs);

  Map<String, String> get names => {
        for (final u in users) u.id: u.getStringValue('name'),
      };
}

class AdminService {
  static PocketBase? _pb;
  static bool get isLoggedIn => _pb?.authStore.isValid ?? false;

  static Future<void> login(String email, String password) async {
    final client = PocketBase(serverUrl);
    await client.collection('_superusers').authWithPassword(email, password);
    _pb = client;
  }

  static void logout() {
    _pb?.authStore.clear();
    _pb = null;
  }

  static Future<AdminSnapshot> load() async {
    final pb = _pb!;
    final users = await pb.collection('users').getFullList(sort: '-created');
    final contacts = await pb.collection('contacts').getFullList(sort: 'owner');
    final shares =
        await pb.collection('location_shares').getFullList(sort: '-updated');
    final pairs = await pb.collection('pair_requests').getFullList();
    return AdminSnapshot(users, contacts, shares, pairs);
  }
}
