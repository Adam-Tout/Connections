import 'package:crushx/sign_up_page.dart';
import 'package:flutter/material.dart';
// Firebase Auth
import 'package:firebase_auth/firebase_auth.dart';
// Google Sign In
import 'package:google_sign_in/google_sign_in.dart';
// Firestore (optional)
import 'package:cloud_firestore/cloud_firestore.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({Key? key}) : super(key: key);

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _formKey = GlobalKey<FormState>();

  // Email/Password controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;

  // Sign in with Email/Password
  Future<void> _signInWithEmailPassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      final user = userCredential.user;

      // CHANGED: Force reload the user to ensure we have the latest verification status.
      if (user != null) {
        await user.reload();
      }

      // 1) Enforce email verification
      if (user != null && !user.emailVerified) {
        // Immediately sign them out
        await FirebaseAuth.instance.signOut();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please verify your email before signing in.'),
          ),
        );
        return;
      }

      // 2) Otherwise, the user is signed in with a verified email
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign-in successful!')),
      );

      // Navigate to your home screen or wherever next
      // Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));

    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign-in failed: ${e.message}')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Sign in with Google
  Future<void> _signInWithGoogle() async {
    setState(() {
      _isLoading = true;
    });

    try {
      print('Google sign-in button clicked'); // CHANGED: Debug print
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();

      if (googleUser == null) {
        // User canceled sign-in or popup blocked
        print('Google sign-in was canceled or blocked'); // CHANGED: Debug print
        setState(() {
          _isLoading = false;
        });
        return;
      }

      print('Google user is $googleUser'); // CHANGED: Debug print
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);

      // You might want to enforce only college-domain emails here:
      final String? email = userCredential.user?.email;
      if (email != null) {
        final domain = email.split('@').last;
        if (!['university.edu', 'college.edu', 'scu.edu'].contains(domain)) {
          await FirebaseAuth.instance.signOut();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please use a valid college Google email')),
          );
          return;
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google Sign-in successful!')),
      );

      // Navigate to home screen, etc.
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Google Sign-in failed: ${e.message}')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Validate email
  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter an email';
    }
    // Simple format check
    if (!value.contains('@') || !value.contains('.')) {
      return 'Invalid email format';
    }
    return null;
  }

  // Validate password
  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a password';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Bold, modern UI with gradient background
    return Scaffold(
      // We add a gradient background here
      body: GestureDetector(
        // This GestureDetector allows you to tap away to dismiss the keyboard
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                children: [
                  // App logo or placeholder
                  Container(
                    width: 100,
                    height: 100,
                    decoration: const BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.favorite,
                      color: Colors.white,
                      size: 50,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // App Name
                  const Text(
                    'Crush Finder',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Sign In text
                  const Text(
                    'Sign in to discover your campus crush!',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 18,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Card with form
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            // Email
                            TextFormField(
                              controller: _emailController,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                prefixIcon: Icon(Icons.email),
                              ),
                              validator: _validateEmail,
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 16),

                            // Password
                            TextFormField(
                              controller: _passwordController,
                              decoration: const InputDecoration(
                                labelText: 'Password',
                                prefixIcon: Icon(Icons.lock),
                              ),
                              obscureText: true,
                              validator: _validatePassword,
                            ),
                            const SizedBox(height: 24),

                            // Sign In button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : _signInWithEmailPassword,
                                style: ElevatedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: const Color(0xFF6A1B9A),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: _isLoading
                                    ? const CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                    : const Text(
                                        'Sign In',
                                        style: TextStyle(fontSize: 18),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Google Sign-In button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isLoading ? null : _signInWithGoogle,
                                icon: const Icon(Icons.login),
                                label: const Text(
                                  'Sign In with Google',
                                  style: TextStyle(fontSize: 16),
                                ),
                                style: ElevatedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.red,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Sign Up link (optional)
                  TextButton(
                    onPressed: () {
                      // Navigate to your Sign Up page
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SignUpPage()));
                    },
                    child: const Text(
                      'Don\'t have an account? Sign up here',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}