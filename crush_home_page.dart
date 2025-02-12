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

  /// We first load the user's college slug, then fetch the user list,
  /// then check for new matches (which show the mutual crush message).
  Future<void> _initPage() async {
    setState(() => _isLoading = true);
    try {
      _collegeSlug = await _getCollegeSlug();
      await _fetchUsersInCollege();
      await _checkForNewMatches(); // see if there's a "mutual crush" doc waiting
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error initializing page: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// Return the college slug from current user's email
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

  /// Fetch all users from the same college, except myself
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
      // ALWAYS skip if doc's id matches my uid
      if (doc.id == currentUserID) {
        continue;
      }

      // Fallback: if doc's email matches mine (in case doc was created incorrectly)
      final data = doc.data();
      final userEmail = data['email'] as String?;
      if (userEmail != null && userEmail == currentUserEmail) {
        continue;
      }

      allUsers.add({
        'id': doc.id, // This should be the other user's UID
        'firstName': data['firstName'] ?? '',
        'lastName': data['lastName'] ?? '',
      });
    }

    _users = allUsers;
  }

  /// Check if we have new "mutual crush" matches where the user hasn't been notified
  Future<void> _checkForNewMatches() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final userId = currentUser.uid;

    // Look for docs in user_matches:
    // (userA == me && notifyA == true) or (userB == me && notifyB == true).
    final matchesQuery = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_matches')
        .where('userA', isEqualTo: userId)
        .where('notifyA', isEqualTo: true)
        .get();

    for (final doc in matchesQuery.docs) {
      final data = doc.data();
      final userBName = data['userBName'] ?? 'Unknown';
      // Show dialog
      await _showMutualCrushDialog(userBName);
      // Mark notifyA = false
      await doc.reference.update({'notifyA': false});
    }

    // Then check (userB == me && notifyB == true)
    final matchesQuery2 = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_matches')
        .where('userB', isEqualTo: userId)
        .where('notifyB', isEqualTo: true)
        .get();

    for (final doc in matchesQuery2.docs) {
      final data = doc.data();
      final userAName = data['userAName'] ?? 'Unknown';
      // Show dialog
      await _showMutualCrushDialog(userAName);
      // Mark notifyB = false
      await doc.reference.update({'notifyB': false});
    }
  }

  /// Called when user clicks "Crush" on someone
  Future<void> _crushOnUser(Map<String, dynamic> otherUser) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No user is logged in.')),
      );
      return;
    }

    final fromUserID = currentUser.uid; // me
    final toUserID = otherUser['id'] as String; // them
    final toUserName = '${otherUser['firstName']} ${otherUser['lastName']}';

    try {
      // 1) Check if I already crush on someone else
      final existingCrushDocSnap =
          await _getExistingCrushDoc(_collegeSlug, fromUserID);
      if (existingCrushDocSnap != null) {
        final oldToUserID = existingCrushDocSnap['toUserID'] as String;
        if (oldToUserID == toUserID) {
          // Already crushing the same person
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
          if (!confirm) return; // user canceled
          // Remove old crush doc
          final docId = '${fromUserID}_$oldToUserID';
          await FirebaseFirestore.instance
              .collection('colleges')
              .doc(_collegeSlug)
              .collection('user_crushes')
              .doc(docId)
              .delete();
        }
      }

      // 2) Now set my new crush doc
      await _setMyCrushOnUser(fromUserID, toUserID);

      // 3) Check if there's a doc for toUserID->fromUserID (mutual crush)
      final mutual = await _checkMutualCrush(toUserID, fromUserID);
      if (mutual) {
        // If mutual, remove both docs from user_crushes and create a doc in user_matches
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

  /// Query user_crushes for fromUserID == me in the same college
  Future<Map<String, dynamic>?> _getExistingCrushDoc(
      String slug, String fromUserID) async {
    final query = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(slug)
        .collection('user_crushes')
        .where('fromUserID', isEqualTo: fromUserID)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return null;
    return query.docs.first.data();
  }

  /// Return a user's name from their doc in Firestore
  Future<String> _getUserNameById(String userID) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('users')
        .doc(userID)
        .get();
    if (!userDoc.exists) return 'Unknown';
    final data = userDoc.data()!;
    final f = data['firstName'] ?? '';
    final l = data['lastName'] ?? '';
    return '$f $l';
  }

  /// Create doc fromUserID->toUserID in user_crushes
  Future<void> _setMyCrushOnUser(String fromUserID, String toUserID) async {
    final docId = '${fromUserID}_$toUserID'; // UID-based
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

  /// Check if there's a doc for toUserID->fromUserID (meaning they liked me)
  Future<bool> _checkMutualCrush(String toUserID, String fromUserID) async {
    final docId = '${toUserID}_$fromUserID';
    final docSnap = await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_crushes')
        .doc(docId)
        .get();
    return docSnap.exists;
  }

  /// If mutual crush:
  /// 1) remove both docs (from->to and to->from)
  /// 2) create a doc in user_matches
  /// 3) show an alert for the local user
  /// 4) the other user sees it next time they load or refresh
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

    // create user_matches doc
    final myName = await _getUserNameById(fromUserID);
    final matchDocId =
        '${fromUserID}_$toUserID'; // or any unique scheme you'd like
    await FirebaseFirestore.instance
        .collection('colleges')
        .doc(_collegeSlug)
        .collection('user_matches')
        .doc(matchDocId)
        .set({
      'userA': fromUserID,
      'userAName': myName,
      'userB': toUserID,
      'userBName': toUserName,
      'matchedAt': Timestamp.now(),
      'notifyA': true, // so A sees the message if they reload or come back
      'notifyB': true, // so B sees it next time they log in or refresh
    });

    // Show local user immediate popup
    _showMutualCrushDialog(toUserName);
  }

  /// Show "YOU AND X BOTH HAVE A CRUSH ON EACH OTHER!"
  Future<void> _showMutualCrushDialog(String partnerName) async {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Mutual Crush!'),
          content: Text(
            'YOU AND $partnerName BOTH HAVE A CRUSH ON EACH OTHER!',
          ),
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

  /// Generic confirm dialog
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
                              // Display the name
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
                              // Crush button
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
