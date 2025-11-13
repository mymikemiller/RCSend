import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:puppeteer/puppeteer.dart';
import 'package:args/args.dart';

// Recipient data structure
class Recipient {
  final String name;
  final String phoneNumber;

  Recipient({required this.name, required this.phoneNumber});

  @override
  String toString() => '$name ($phoneNumber)';
}

// State tracking
class SendState {
  Map<String, String> phoneStatus = {}; // phone -> 'pending'|'sent'|'failed'

  SendState();

  factory SendState.fromJson(Map<String, dynamic> json) {
    final state = SendState();
    state.phoneStatus = Map<String, String>.from(json['phoneStatus'] ?? {});
    return state;
  }

  Map<String, dynamic> toJson() => {
    'phoneStatus': phoneStatus,
  };

  void save(String filePath) {
    File(filePath).writeAsStringSync(jsonEncode(toJson()));
  }

  static SendState load(String filePath) {
    if (!File(filePath).existsSync()) {
      return SendState();
    }
    final json = jsonDecode(File(filePath).readAsStringSync());
    return SendState.fromJson(json);
  }
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('phones-file', abbr: 'f', help: 'Path to file containing phone numbers (newline-separated)', mandatory: true)
    ..addOption('message', abbr: 'm', help: 'Message text to send (optional if -i is provided)')
    ..addOption('image', abbr: 'i', help: 'Path to image file to attach')
    ..addOption('state-file', abbr: 's', help: 'Path to state tracking file', defaultsTo: '.send_state.json')
    ..addFlag('dry-run', abbr: 'n', help: 'Test mode - simulate without actually sending', negatable: false)
    ..addFlag('debug', abbr: 'd', help: 'Enable debug mode', negatable: false)
    ..addFlag('help', abbr: 'h', help: 'Show this help message', negatable: false);

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    print('Error parsing arguments: $e\n');
    print(parser.usage);
    exit(1);
  }

  if (argResults['help'] as bool) {
    print('Usage: dart send_batch.dart -f <phones_file> -m <message> [-i <image>] [--dry-run]');
    print('\nBatch send messages to multiple recipients.\n');
    print(parser.usage);
    exit(0);
  }

  final phonesFile = argResults['phones-file'] as String;
  final messageText = argResults['message'] as String?;
  final imagePath = argResults['image'] as String?;
  final stateFile = argResults['state-file'] as String;
  final dryRun = argResults['dry-run'] as bool;
  final debugMode = argResults['debug'] as bool;

  // Validate that at least one of message or image is provided
  if (messageText == null && imagePath == null) {
    print('Error: Must provide either -m (message) or -i (image), or both');
    print('');
    print(parser.usage);
    exit(1);
  }

  // Validate phones file exists
  if (!File(phonesFile).existsSync()) {
    print('Error: Phones file not found at: $phonesFile');
    exit(1);
  }

  // Validate image path if provided
  if (imagePath != null) {
    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) {
      print('Error: Image file not found at: $imagePath');
      exit(1);
    }
  }

  // Read recipients (supports "name: number" or just "number" format)
  final recipients = <Recipient>[];
  final lines = File(phonesFile).readAsLinesSync();

  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    // Check if line contains "name: number" format
    if (line.contains(':')) {
      final parts = line.split(':');
      if (parts.length >= 2) {
        final name = parts[0].trim();
        final phoneNumber = parts.sublist(1).join(':').trim(); // Handle cases where phone has ':'
        recipients.add(Recipient(name: name, phoneNumber: phoneNumber));
      }
    } else {
      // Just a phone number, use it as both name and number
      recipients.add(Recipient(name: line, phoneNumber: line));
    }
  }

  if (recipients.isEmpty) {
    print('Error: No recipients found in file: $phonesFile');
    exit(1);
  }

  print('═══════════════════════════════════════════════════════════');
  print('  BATCH SEND ${dryRun ? "(DRY RUN MODE)" : ""}');
  print('═══════════════════════════════════════════════════════════');
  print('Recipients: ${recipients.length}');
  if (messageText != null) print('Message: $messageText');
  if (imagePath != null) print('Image: $imagePath');
  print('State file: $stateFile');
  print('═══════════════════════════════════════════════════════════');
  print('');

  // Load state
  final state = SendState.load(stateFile);

  // Initialize any new phone numbers as pending
  for (var recipient in recipients) {
    state.phoneStatus.putIfAbsent(recipient.phoneNumber, () => 'pending');
  }
  state.save(stateFile);

  // Count statuses
  int pendingCount = state.phoneStatus.values.where((s) => s == 'pending').length;
  int sentCount = state.phoneStatus.values.where((s) => s == 'sent').length;
  int failedCount = state.phoneStatus.values.where((s) => s == 'failed').length;

  print('Status: $sentCount sent, $failedCount failed, $pendingCount pending');
  print('');

  if (pendingCount == 0) {
    print('All messages already sent! Nothing to do.');
    exit(0);
  }

  if (dryRun) {
    print('DRY RUN MODE - Simulating sends...');
    for (var recipient in recipients) {
      if (state.phoneStatus[recipient.phoneNumber] == 'pending') {
        print('  Would send to: ${recipient.name} (${recipient.phoneNumber})');
      }
    }
    print('');
    print('Dry run complete. Use without --dry-run to actually send.');
    exit(0);
  }

  // Launch browser
  print('Starting browser automation...');
  final browser = await puppeteer.launch(
    headless: false,
    userDataDir: './user_data',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-blink-features=AutomationControlled',
      '--disable-dev-shm-usage',
      '--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    ],
  );

  try {
    final page = await browser.newPage();
    await page.setViewport(DeviceViewport(width: 1280, height: 800));

    // Hide webdriver properties
    await page.evaluateOnNewDocument('''() => {
      Object.defineProperty(navigator, 'webdriver', {
        get: () => undefined
      });
      window.navigator.chrome = { runtime: {} };
      Object.defineProperty(navigator, 'plugins', {
        get: () => [1, 2, 3, 4, 5]
      });
      Object.defineProperty(navigator, 'languages', {
        get: () => ['en-US', 'en']
      });
    }''');

    print('Opening Google Messages...');
    await page.goto('https://messages.google.com/web',
      wait: Until.domContentLoaded,
      timeout: Duration(seconds: 60));

    print('Waiting for Google Messages to be ready...');
    print('(If you need to log in or pair your phone, please do so now)');
    print('');

    // Wait for the Start chat button to appear
    final startChatSelectors = [
      '[data-e2e-start-button]',
      'a[href*="conversations/new"]',
      'a[href="#new"]',
      'button[mattooltip="Start chat"]',
      'button[aria-label="Start chat"]',
      '[class*="fab"]',
    ];

    bool pageReady = false;
    String? foundSelector;
    for (var selector in startChatSelectors) {
      try {
        if (debugMode) print('  Checking for: $selector');
        await page.waitForSelector(selector, timeout: Duration(seconds: 5));
        print('✓ Google Messages is ready! (Found: $selector)');
        pageReady = true;
        foundSelector = selector;
        await Future.delayed(Duration(milliseconds: 1000));
        break;
      } catch (e) {
        if (debugMode) print('  Not found: $selector');
        continue;
      }
    }

    if (!pageReady) {
      print('ERROR: Could not detect Google Messages ready state.');
      await browser.close();
      exit(1);
    }

    print('');
    print('Starting batch send...');
    print('');

    // Process each pending recipient
    int processedCount = sentCount;
    int totalCount = recipients.length;

    for (var recipient in recipients) {
      if (state.phoneStatus[recipient.phoneNumber] != 'pending') {
        continue; // Skip already processed
      }

      processedCount++;
      final percentage = (processedCount * 100 / totalCount).toStringAsFixed(1);

      print('[$processedCount/$totalCount - $percentage%] Sending to: ${recipient.name} (${recipient.phoneNumber})');

      try {
        // Send the message
        final success = await sendMessage(
          page: page,
          phoneNumber: recipient.phoneNumber,
          messageText: messageText,
          imagePath: imagePath,
          startChatSelector: foundSelector!,
          debugMode: debugMode,
        );

        if (success) {
          state.phoneStatus[recipient.phoneNumber] = 'sent';
          state.save(stateFile);
          print('  ✓ Successfully sent to ${recipient.name}');
        } else {
          throw Exception('Send verification failed');
        }

      } catch (e) {
        print('  ✗ ERROR sending to ${recipient.name}: $e');
        state.phoneStatus[recipient.phoneNumber] = 'failed';
        state.save(stateFile);

        // Stop and ask user what to do
        print('');
        print('╔════════════════════════════════════════════════════════════════╗');
        print('║  ERROR OCCURRED                                                ║');
        print('╠════════════════════════════════════════════════════════════════╣');
        final recipientInfo = '${recipient.name} (${recipient.phoneNumber})';
        final paddingNeeded = 47 - recipientInfo.length;
        print('║  Failed to send to: $recipientInfo${' ' * (paddingNeeded > 0 ? paddingNeeded : 0)}║');
        final errorStr = e.toString();
        final errorDisplay = errorStr.length > 54 ? errorStr.substring(0, 51) + '...' : errorStr.padRight(54);
        print('║  Error: $errorDisplay║');
        print('║                                                                ║');
        print('║  What would you like to do?                                    ║');
        print('║    [R] Retry this recipient                                    ║');
        print('║    [S] Skip this recipient and continue                        ║');
        print('║    [A] Abort batch send                                        ║');
        print('╚════════════════════════════════════════════════════════════════╝');
        print('');
        print('Enter choice (R/S/A): ');

        final choice = stdin.readLineSync()?.toUpperCase() ?? 'A';

        if (choice == 'R') {
          // Reset to pending and retry
          state.phoneStatus[recipient.phoneNumber] = 'pending';
          state.save(stateFile);
          processedCount--; // Don't count this attempt
          print('Retrying...');
          continue;
        } else if (choice == 'S') {
          print('Skipping ${recipient.name} and continuing...');
          continue;
        } else {
          print('Aborting batch send.');
          break;
        }
      }

      print('');
    }

    print('');
    print('═══════════════════════════════════════════════════════════');
    print('  BATCH SEND COMPLETE');
    print('═══════════════════════════════════════════════════════════');

    // Final count
    sentCount = state.phoneStatus.values.where((s) => s == 'sent').length;
    failedCount = state.phoneStatus.values.where((s) => s == 'failed').length;
    pendingCount = state.phoneStatus.values.where((s) => s == 'pending').length;

    print('Final status:');
    print('  ✓ Sent: $sentCount');
    print('  ✗ Failed: $failedCount');
    print('  • Pending: $pendingCount');
    print('═══════════════════════════════════════════════════════════');
    print('');

    print('Keeping browser open for 5 seconds...');
    await Future.delayed(Duration(seconds: 5));

  } catch (e) {
    print('Error: $e');
    print('Stack trace: ${StackTrace.current}');
    exit(1);
  } finally {
    await browser.close();
    print('Browser closed.');
  }
}

/// Sends a message to a single recipient and verifies it was sent
Future<bool> sendMessage({
  required Page page,
  required String phoneNumber,
  required String? messageText,
  required String? imagePath,
  required String startChatSelector,
  required bool debugMode,
}) async {
  try {
    // Click the "Start chat" button to begin new conversation
    await page.evaluate('''(selector) => {
      const element = document.querySelector(selector);
      if (element) {
        element.scrollIntoView();
        element.click();
        return true;
      }
      return false;
    }''', args: [startChatSelector]);

    await Future.delayed(Duration(milliseconds: 2000));

    // Type the phone number
    await page.keyboard.type(phoneNumber, delay: Duration(milliseconds: 50));

    // Wait for autocomplete to appear
    await Future.delayed(Duration(milliseconds: 2000));

    // Press Enter to confirm the recipient
    await page.keyboard.press(Key.enter);

    // Give extra time for conversation to open
    await Future.delayed(Duration(milliseconds: 2000));

    // Wait for the message input box to appear
    final messageFieldSelectors = [
      '[data-e2e-message-input-box]',
      'div[contenteditable="true"]',
      '[role="textbox"]',
      '[aria-label*="Text message"]',
    ];

    bool messageFieldFound = false;
    String? messageFieldSelector;
    for (var selector in messageFieldSelectors) {
      try {
        await page.waitForSelector(selector, timeout: Duration(seconds: 15));
        messageFieldSelector = selector;
        messageFieldFound = true;
        await Future.delayed(Duration(milliseconds: 500));
        break;
      } catch (e) {
        continue;
      }
    }

    if (!messageFieldFound || messageFieldSelector == null) {
      throw Exception('Could not find message field');
    }

    // Click the message field to focus it
    final field = await page.$(messageFieldSelector);
    if (field != null) {
      await field.click();
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Type the message text first if provided
    if (messageText != null && messageText.isNotEmpty) {
      await page.keyboard.type(messageText, delay: Duration(milliseconds: 30));
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Attach image if provided
    if (imagePath != null) {
      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final imageBase64 = base64Encode(imageBytes);
      final imageName = imagePath.split('/').last;

      final scriptWithData = '''
        (async () => {
          const imageBase64 = "$imageBase64";
          const imageName = "$imageName";

          try {
            const response = await fetch('data:image/jpeg;base64,' + imageBase64);
            const blob = await response.blob();
            const file = new File([blob], imageName, { type: blob.type });

            const dropTarget = document.querySelector('[contenteditable="true"]') ||
                              document.querySelector('[role="textbox"]') ||
                              document.body;

            const dataTransfer = new DataTransfer();
            dataTransfer.items.add(file);

            const dropEvent = new DragEvent('drop', {
              dataTransfer: dataTransfer,
              bubbles: true,
              cancelable: true
            });

            dropTarget.dispatchEvent(dropEvent);

            const pasteEvent = new ClipboardEvent('paste', {
              clipboardData: dataTransfer,
              bubbles: true,
              cancelable: true
            });
            dropTarget.dispatchEvent(pasteEvent);

            return true;
          } catch (e) {
            console.error('Drop simulation error:', e);
            return false;
          }
        })()
      ''';

      await page.evaluate(scriptWithData);
      await Future.delayed(Duration(milliseconds: 3000));
    }

    // Wait a moment to ensure both text and image are in the compose area
    if (imagePath != null && messageText != null) {
      await Future.delayed(Duration(milliseconds: 1000));
    }

    // Send with Ctrl+Enter
    await page.keyboard.down(Key.control);
    await page.keyboard.press(Key.enter);
    await page.keyboard.up(Key.control);

    // Wait for message to be sent and verify
    await Future.delayed(Duration(seconds: 2));

    // Check for confirmation: wait for div with class "text-msg msg-content" containing the sent text
    if (messageText != null && messageText.isNotEmpty) {
      final verified = await waitForMessageConfirmation(page, messageText, debugMode);
      if (!verified) {
        throw Exception('Message confirmation not found');
      }
    } else {
      // For image-only messages, just wait a bit longer
      await Future.delayed(Duration(seconds: 2));
    }

    // Navigate back to main screen for next message
    await page.goto('https://messages.google.com/web',
      wait: Until.domContentLoaded,
      timeout: Duration(seconds: 30));

    // Wait for start chat button again
    await page.waitForSelector(startChatSelector, timeout: Duration(seconds: 10));
    await Future.delayed(Duration(milliseconds: 1000));

    return true;

  } catch (e) {
    if (debugMode) {
      print('    Debug: sendMessage error: $e');
    }
    rethrow;
  }
}

/// Waits for and verifies that the message was sent by looking for the confirmation div
Future<bool> waitForMessageConfirmation(Page page, String messageText, bool debugMode) async {
  try {
    // Wait up to 10 seconds for the message to appear in the conversation
    final timeout = DateTime.now().add(Duration(seconds: 10));

    while (DateTime.now().isBefore(timeout)) {
      // Look for div with class "text-msg msg-content" that contains the message text
      final found = await page.evaluate('''(messageText) => {
        const messageDivs = document.querySelectorAll('.text-msg.msg-content');
        for (let div of messageDivs) {
          if (div.textContent && div.textContent.includes(messageText)) {
            return true;
          }
        }
        return false;
      }''', args: [messageText]);

      if (found == true) {
        if (debugMode) print('    Debug: Message confirmation found');
        return true;
      }

      await Future.delayed(Duration(milliseconds: 500));
    }

    if (debugMode) print('    Debug: Message confirmation NOT found after timeout');
    return false;

  } catch (e) {
    if (debugMode) print('    Debug: waitForMessageConfirmation error: $e');
    return false;
  }
}
