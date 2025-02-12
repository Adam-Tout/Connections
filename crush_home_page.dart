import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// A simple domain->slug map
final Map<String, String> domainMap = {
  'scu.edu': 'scu',
  'university.edu': 'university',
  'college.edu': 'college',
  // Add more as needed
};

class CrushHomePage extends StatefulWidget {
  const CrushHomePage({Key? key}) : super(key: key);

  @override
  State<CrushHomePage> createState() => _CrushHomePageState();
}

class _CrushHomePageState extends State<CrushHomePage> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _users = [];
  String _collegeSlug = 'unknown_college';

  @override
  void initState() {
    super.initState();
    _initPage();
  }

  /// 1) Determine user’s college slug, fetch users, then check for notifications
  Future<void> _initPage() async {
    setState(() => _isLoading = true);
    try {
      _collegeSlug = await _getCollegeSlug();
      await _fetchUsersInCollege();
      await _checkForNotifications(); // see if we have unread mutual crush notifications
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error initializing page: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 2) Return the college slug from user’s email
  Future<String> _getCollegeSlug() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      throw Exception('No user is logged in.');
    }
    final email = currentUser.email;
    if (email == null) {
      throw Exception('No email found for user.');
    }
    final domain = email.split('@').last;
    return domainMap[domain] ?? 'unknown_college';
  }

  /// 3) Fetch all users from the same college (except me)
  Future<void> _fetchUsersInCollege() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      throw Exception('No user is logged in.');
    }
    final currentUserID = currentUser.uid;
    final currentUserEmail = currentUser.email;

    final querySnap = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('users')
        .get();

    final allUsers = <Map<String, dynamic>>[];
    for (final doc in querySnap.docs) {
      if (doc.id == currentUserID) continue;

      final data = doc.data();
      final userEmail = data['email'] as String?;
      if (userEmail != null && userEmail == currentUserEmail) {
        continue;
      }

      allUsers.add({
        'id': doc.id,
        'firstName': data['firstName'] ?? '',
        'lastName': data['lastName'] ?? '',
      });
    }
    setState(() {
      _users = allUsers;
    });
  }

  // --------------------------------------------------------------------------
  // NOTIFICATION (MUTUAL CRUSH) LOGIC
  // --------------------------------------------------------------------------

  /// 4) Check if we have new “mutual crush” notifications in notify_crushes
  Future<void> _checkForNotifications() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final uid = currentUser.uid;

    // A) where userA == me && notifyA == true
    final notifyAQuery = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('notify_crushes')
        .where('userA', isEqualTo: uid)
        .where('notifyA', isEqualTo: true)
        .get();

    for (final doc in notifyAQuery.docs) {
      final data = doc.data();
      final userBName = data['userBName']?.toString().toUpperCase() ?? 'UNKNOWN';
      // show local pop-up
      await _showNotifyDialog(userBName);
      // set notifyA = false
      await doc.reference.update({'notifyA': false});
      // If notifyB == false also, remove doc
      await _maybeRemoveNotifyDoc(doc.reference);
    }

    // B) where userB == me && notifyB == true
    final notifyBQuery = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('notify_crushes')
        .where('userB', isEqualTo: uid)
        .where('notifyB', isEqualTo: true)
        .get();

    for (final doc in notifyBQuery.docs) {
      final data = doc.data();
      final userAName = data['userAName']?.toString().toUpperCase() ?? 'UNKNOWN';
      // show local pop-up
      await _showNotifyDialog(userAName);
      // set notifyB = false
      await doc.reference.update({'notifyB': false});
      // remove doc if notifyA == false and notifyB == false
      await _maybeRemoveNotifyDoc(doc.reference);
    }
  }

  /// 5) If both notifyA & notifyB are false, remove the doc
  Future<void> _maybeRemoveNotifyDoc(DocumentReference docRef) async {
    final snap = await docRef.get();
    if (!snap.exists) return; // doc was removed or something else
    final data = snap.data() as Map<String, dynamic>?;
    if (data == null) return;

    final notifyA = data['notifyA'] as bool? ?? false;
    final notifyB = data['notifyB'] as bool? ?? false;
    if (!notifyA && !notifyB) {
      // both false, remove doc
      await docRef.delete();
    }
  }

  /// 6) Popup for a mutual crush from notify_crushes
  Future<void> _showNotifyDialog(String partnerName) async {
    return showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Mutual Crush!'),
          content: Text('YOU AND $partnerName BOTH HAVE A CRUSH ON EACH OTHER!'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Awesome!'),
            ),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // CRUSH LOGIC
  // --------------------------------------------------------------------------

  /// 7) Called when user clicks "Crush"
  Future<void> _crushOnUser(Map<String, dynamic> otherUser) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No user is logged in.')),
      );
      return;
    }
    final fromUserID = currentUser.uid;
    final toUserID = otherUser['id'] as String;
    final toUserName = '${otherUser['firstName']} ${otherUser['lastName']}';

    try {
      // A) check if I already crush on someone else
      final existingCrush = await _getExistingCrushDoc(fromUserID);
      if (existingCrush != null) {
        final oldToUserID = existingCrush['toUserID'] as String;
        if (oldToUserID == toUserID) {
          // Already crushing them
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('You already have a crush on $toUserName!')),
          );
          return;
        } else {
          // I'm crushing on a different user
          final oldUserName = await _getUserNameById(oldToUserID);
          final confirm = await _showConfirmDialog(
            title: 'Already have a crush!',
            content:
                'You already like $oldUserName.\nSwitch your crush to $toUserName?',
          );
          if (!confirm) return; // canceled
          // remove old doc
          final oldDocId = '${fromUserID}_$oldToUserID';
          await FirebaseFirestore.instance
              .collection('colleges')
              .doc(_collegeSlug)
              .collection('user_crushes')
              .doc(oldDocId)
              .delete();
        }
      }

      // B) Now set my new crush doc
      await _setMyCrushOnUser(fromUserID, toUserID);

      // C) check if user B already liked me
      final mutual = await _checkMutualCrush(toUserID, fromUserID);
      if (mutual) {
        // remove both docs from user_crushes, create doc in notify_crushes
        await _handleMutualCrush(fromUserID, toUserID, toUserName);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Crush saved on $toUserName!')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error crushing on $toUserName: $e')),
      );
    }
  }

  /// 8) Return doc if I have an existing crush
  Future<Map<String, dynamic>?> _getExistingCrushDoc(String fromUserID) async {
    final query = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .where('fromUserID', isEqualTo: fromUserID)
        .limit(1)
        .get();
    if (query.docs.isEmpty) return null;
    return query.docs.first.data();
  }

  /// 9) Return the user’s name from Firestore
  Future<String> _getUserNameById(String userID) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('users')
        .doc(userID)
        .get();
    if (!userDoc.exists) return 'Unknown';
    final data = userDoc.data()!;
    final firstName = data['firstName'] ?? '';
    final lastName = data['lastName'] ?? '';
    return '$firstName $lastName';
  }

  /// 10) Create doc in user_crushes
  Future<void> _setMyCrushOnUser(String fromUserID, String toUserID) async {
    final docId = '${fromUserID}_$toUserID';
    await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .doc(docId)
        .set({
      'fromUserID': fromUserID,
      'toUserID': toUserID,
      'timestamp': Timestamp.now(),
    });
  }

  /// 11) Check if doc to->from exists
  Future<bool> _checkMutualCrush(String toUserID, String fromUserID) async {
    final docId = '${toUserID}_$fromUserID';
    final snap = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .doc(docId)
        .get();
    return snap.exists;
  }

  /// 12) If mutual: remove from->to, remove to->from, create doc in notify_crushes
  Future<void> _handleMutualCrush(
      String fromUserID, String toUserID, String toUserName) async {
    // remove from->to
    final docId1 = '${fromUserID}_$toUserID';
    await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .doc(docId1)
        .delete();

    // remove to->from
    final docId2 = '${toUserID}_$fromUserID';
    await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .doc(docId2)
        .delete();

    // create doc in notify_crushes
    final myName = await _getUserNameById(fromUserID);
    final notifyDocId = '${fromUserID}_$toUserID';
    await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('notify_crushes')
        .doc(notifyDocId)
        .set({
      'userA': fromUserID,
      'userAName': myName.toUpperCase(), // store my name in CAPS or up to you
      'userB': toUserID,
      'userBName': toUserName.toUpperCase(), // store partner name in CAPS
      'createdAt': Timestamp.now(),
      'notifyA': true, // so I see it if I refresh
      'notifyB': true, // so they see it next time
    });

    // show me local popup
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mutual Crush!'),
        content: Text(
          'YOU AND ${toUserName.toUpperCase()} BOTH HAVE A CRUSH ON EACH OTHER!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Awesome!'),
          ),
        ],
      ),
    );
  }

  /// 13) Confirm dialog
  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: Text(title),
              content: Text(content),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        )) ==
        true;
  }

  // --------------------------------------------------------------------------
  // BUILD
  // --------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crush Home'),
        backgroundColor: const Color(0xFF6A1B9A),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _users.isEmpty
                ? const Center(
                    child: Text(
                      'No users found in your college.',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16.0),
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      final fullName =
                          '${user['firstName']} ${user['lastName']}';

                      return Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        color: Colors.white.withOpacity(0.9),
                        margin: const EdgeInsets.only(bottom: 16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  fullName,
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ElevatedButton(
                                onPressed: () => _crushOnUser(user),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.pinkAccent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text('Crush'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
