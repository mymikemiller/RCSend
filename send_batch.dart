import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:puppeteer/puppeteer.dart';
import 'package:args/args.dart';

// Recipient data structure
class Recipient {
  final String name;
  final List<String> phoneNumbers; // Support multiple numbers for group messages

  Recipient({required this.name, required this.phoneNumbers});

  // For state tracking, use concatenated phone numbers as key
  String get stateKey => phoneNumbers.join(',');

  bool get isGroup => phoneNumbers.length > 1;

  @override
  String toString() {
    if (isGroup) {
      return '$name (${phoneNumbers.length} recipients: ${phoneNumbers.join(", ")})';
    }
    return '$name (${phoneNumbers[0]})';
  }
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
    ..addOption('phones-file', abbr: 'p', help: 'Path to file containing phone numbers (newline-separated)', mandatory: true)
    ..addOption('message', abbr: 'm', help: 'Message text to send (optional if -i or -f is provided)')
    ..addOption('file', abbr: 'f', help: 'Path to file containing message text')
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
    print('Usage: dart send_batch.dart -p <phones_file> [-m <message> | -f <message_file>] [-i <image>] [--dry-run]');
    print('\nBatch send messages to multiple recipients.\n');
    print(parser.usage);
    exit(0);
  }

  final phonesFile = argResults['phones-file'] as String;
  final messageTextArg = argResults['message'] as String?;
  final messageFilePath = argResults['file'] as String?;
  final imagePath = argResults['image'] as String?;
  final stateFile = argResults['state-file'] as String;
  final dryRun = argResults['dry-run'] as bool;
  final debugMode = argResults['debug'] as bool;

  // Validate that at most one of -m or -f is provided
  if (messageTextArg != null && messageFilePath != null) {
    print('Error: Cannot use both -m (message) and -f (file) at the same time');
    print('');
    print(parser.usage);
    exit(1);
  }

  // Load message text from file if -f is provided
  String? messageText = messageTextArg;
  if (messageFilePath != null) {
    final messageFile = File(messageFilePath);
    if (!messageFile.existsSync()) {
      print('Error: Message file not found at: $messageFilePath');
      exit(1);
    }
    messageText = messageFile.readAsStringSync();
    print('Message loaded from file: $messageFilePath');
  }

  // Validate that at least one of message or image is provided
  if (messageText == null && imagePath == null) {
    print('Error: Must provide either -m (message), -f (file), or -i (image), or a combination');
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

  // Read recipients (supports "name: number" or "name: number1, number2" or just "number" format)
  final recipients = <Recipient>[];
  final lines = File(phonesFile).readAsLinesSync();

  // First pass: validate all lines before processing
  int lineNumber = 0;
  for (var line in lines) {
    lineNumber++;
    final trimmedLine = line.trim();
    if (trimmedLine.isEmpty) continue;

    // Check if line contains "name: number(s)" format
    if (trimmedLine.contains(':')) {
      final parts = trimmedLine.split(':');
      if (parts.length >= 2) {
        final name = parts[0].trim();
        final numbersString = parts.sublist(1).join(':').trim();

        // Validate name is not empty
        if (name.isEmpty) {
          print('Error on line $lineNumber: Name is empty before colon');
          print('Line content: "$trimmedLine"');
          print('Expected format: "Name: +1234567890" or "Name: +1234567890, +0987654321"');
          exit(1);
        }

        // Split by comma to handle multiple numbers (for group messages)
        final phoneNumbers = numbersString
            .split(',')
            .map((n) => n.trim())
            .where((n) => n.isNotEmpty)
            .toList();

        // Validate at least one phone number exists
        if (phoneNumbers.isEmpty) {
          print('Error on line $lineNumber: No phone numbers found after colon');
          print('Line content: "$trimmedLine"');
          print('Expected format: "Name: +1234567890" or "Name: +1234567890, +0987654321"');
          exit(1);
        }
      } else {
        // Colon exists but not enough parts
        print('Error on line $lineNumber: Invalid format with colon');
        print('Line content: "$trimmedLine"');
        print('Expected format: "Name: +1234567890" or "Name: +1234567890, +0987654321"');
        exit(1);
      }
    }
    // Lines without colons are treated as phone numbers (valid)
  }

  // Second pass: build recipients list (validation already passed)
  lineNumber = 0;
  for (var line in lines) {
    lineNumber++;
    line = line.trim();
    if (line.isEmpty) continue;

    // Check if line contains "name: number(s)" format
    if (line.contains(':')) {
      final parts = line.split(':');
      if (parts.length >= 2) {
        final name = parts[0].trim();
        final numbersString = parts.sublist(1).join(':').trim(); // Handle cases where phone has ':'

        // Split by comma to handle multiple numbers (for group messages)
        final phoneNumbers = numbersString
            .split(',')
            .map((n) => n.trim())
            .where((n) => n.isNotEmpty)
            .toList();

        if (phoneNumbers.isNotEmpty) {
          recipients.add(Recipient(name: name, phoneNumbers: phoneNumbers));
        }
      }
    } else {
      // Just a phone number, use it as both name and number
      recipients.add(Recipient(name: line, phoneNumbers: [line]));
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

  // Initialize any new recipients as pending (using stateKey for groups)
  for (var recipient in recipients) {
    state.phoneStatus.putIfAbsent(recipient.stateKey, () => 'pending');
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
      if (state.phoneStatus[recipient.stateKey] == 'pending') {
        print('  Would send to: $recipient');
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
        await Future.delayed(Duration(milliseconds: 250));
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
      if (state.phoneStatus[recipient.stateKey] != 'pending') {
        continue; // Skip already processed
      }

      processedCount++;
      final percentage = (processedCount * 100 / totalCount).toStringAsFixed(1);

      print('[$processedCount/$totalCount - $percentage%] Sending to: $recipient');

      try {
        // Send the message (pass all phone numbers for group messages)
        final success = await sendMessage(
          page: page,
          phoneNumbers: recipient.phoneNumbers,
          messageText: messageText,
          imagePath: imagePath,
          startChatSelector: foundSelector!,
          debugMode: debugMode,
        );

        if (success) {
          state.phoneStatus[recipient.stateKey] = 'sent';
          state.save(stateFile);
          print('  ✓ Successfully sent to ${recipient.name}');
        } else {
          throw Exception('Send verification failed');
        }

      } catch (e) {
        print('  ✗ ERROR sending to ${recipient.name}: $e');
        state.phoneStatus[recipient.stateKey] = 'failed';
        state.save(stateFile);

        // Stop and ask user what to do
        print('');
        print('╔════════════════════════════════════════════════════════════════╗');
        print('║  ERROR OCCURRED                                                ║');
        print('╠════════════════════════════════════════════════════════════════╣');
        final recipientStr = recipient.toString();
        final recipientDisplay = recipientStr.length > 47 ? recipientStr.substring(0, 44) + '...' : recipientStr.padRight(47);
        print('║  Failed to send to: $recipientDisplay║');
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
          state.phoneStatus[recipient.stateKey] = 'pending';
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
    await Future.delayed(Duration(milliseconds: 2500));

  } catch (e) {
    print('Error: $e');
    print('Stack trace: ${StackTrace.current}');
    exit(1);
  } finally {
    await browser.close();
    print('Browser closed.');
  }
}

/// Sends a message to one or more recipients (supports group messages) and verifies it was sent
Future<bool> sendMessage({
  required Page page,
  required List<String> phoneNumbers,
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

    await Future.delayed(Duration(milliseconds: 1000));

    // For group messages with multiple recipients, check for existing group first
    if (phoneNumbers.length > 1) {
      // Click "Start group chat" button
      final groupChatClicked = await page.evaluate('''() => {
        const selectors = [
          '[data-e2e-start-group-chat-button]',
          '[data-e2e-start-group-chat-button=""]',
          'button[aria-label*="group"]',
        ];

        for (const selector of selectors) {
          const btn = document.querySelector(selector);
          if (btn) {
            btn.click();
            return selector;
          }
        }
        return null;
      }''');

      if (groupChatClicked == null) {
        throw Exception('Could not find "Start group chat" button');
      }

      if (debugMode) print('  Clicked Start group chat button: $groupChatClicked');
      await Future.delayed(Duration(milliseconds: 350));

      // Type all phone numbers and press Enter after each to trigger group suggestions
      for (int i = 0; i < phoneNumbers.length; i++) {
        await page.keyboard.type(phoneNumbers[i], delay: Duration(milliseconds: 50));
        await Future.delayed(Duration(milliseconds: 1000));
        await page.keyboard.press(Key.enter);
        await Future.delayed(Duration(milliseconds: 1000));
      }

      // Wait for group suggestions to appear (Google Messages can be slow)
      if (debugMode) print('  Waiting for group suggestions to load...');
      await Future.delayed(Duration(milliseconds: 1500));

      // Trigger group suggestions by deleting and retyping last character of last number
      // if (debugMode) print('  Triggering group suggestions refresh...');
      // await page.keyboard.press(Key.backspace);
      // await Future.delayed(Duration(milliseconds: 500));
      // final lastChar = phoneNumbers.last.substring(phoneNumbers.last.length - 1);
      // await page.keyboard.type(lastChar);
      // await Future.delayed(Duration(milliseconds: 500));

      // Wait extra time for groups to appear
      await Future.delayed(Duration(seconds: 1));

      // Check if there's an existing group with these exact participants
      final existingGroupFound = await page.evaluate('''() => {
        const groupList = document.querySelector('.group-conversations-list');
        if (groupList) {
          const firstGroup = groupList.querySelector('[data-e2e-group-conversation-item]');
          if (firstGroup) {
            firstGroup.click();
            return true;
          }
        }
        return false;
      }''');

      if (existingGroupFound) {
        if (debugMode) print('  Found existing group conversation, checking participants...');
        await Future.delayed(Duration(milliseconds: 500));

        // Click conversation menu to open details
        final menuClicked = await page.evaluate('''() => {
          const menuBtn = document.querySelector('[data-e2e-conversation-menu-button]');
          if (menuBtn) {
            menuBtn.click();
            return true;
          }
          return false;
        }''');

        if (menuClicked) {
          await Future.delayed(Duration(milliseconds: 250));

          // Click Details button
          final detailsClicked = await page.evaluate('''() => {
            const detailsBtn = document.querySelector('[data-e2e-details-button]');
            if (detailsBtn) {
              detailsBtn.click();
              return true;
            }
            return false;
          }''');

          if (detailsClicked) {
            await Future.delayed(Duration(milliseconds: 500));

            // Get all participant numbers from details
            final participantNumbers = await page.evaluate('''() => {
              const participants = Array.from(document.querySelectorAll('[data-e2e-details-participant-number]'));
              return participants.map(p => p.textContent.trim());
            }''');

            if (debugMode) print('  Group participants: $participantNumbers');

            // Normalize and compare phone numbers (strip non-digits, then remove leading 1 for US numbers)
            String normalizePhone(String phone) {
              var digits = phone.replaceAll(RegExp(r'[^\d]'), '');
              // Remove leading 1 (US country code) if it's an 11-digit number
              if (digits.length == 11 && digits.startsWith('1')) {
                digits = digits.substring(1);
              }
              return digits;
            }

            final normalizedExpected = phoneNumbers.map(normalizePhone).toSet();
            final normalizedFound = (participantNumbers as List).map((n) => normalizePhone(n.toString())).toSet();

            if (normalizedExpected.length == normalizedFound.length &&
                normalizedExpected.difference(normalizedFound).isEmpty) {
              if (debugMode) print('  ✓ Existing group matches! Using this conversation.');

              // Close details and return to conversation
              await page.keyboard.press(Key.escape);
              await Future.delayed(Duration(milliseconds: 250));

              // We're already in the right conversation, skip group creation
            } else {
              if (debugMode) print('  ✗ Group participants don\'t match. Creating new group...');

              // Close details and go back
              await page.keyboard.press(Key.escape);
              await Future.delayed(Duration(milliseconds: 125));
              await page.keyboard.press(Key.escape);
              await Future.delayed(Duration(milliseconds: 250));

              // Need to start over with group creation
              await page.evaluate('''(selector) => {
                const element = document.querySelector(selector);
                if (element) element.click();
              }''', args: [startChatSelector]);
              await Future.delayed(Duration(milliseconds: 500));

              final groupChatRetry = await page.evaluate('''() => {
                const btn = document.querySelector('[data-e2e-start-group-chat-button]');
                if (btn) {
                  btn.click();
                  return true;
                }
                return false;
              }''');

              if (!groupChatRetry) {
                throw Exception('Could not restart group chat creation');
              }

              await Future.delayed(Duration(milliseconds: 350));

              // Add all recipients properly this time
              for (int i = 0; i < phoneNumbers.length; i++) {
                await page.keyboard.type(phoneNumbers[i], delay: Duration(milliseconds: 50));
                await Future.delayed(Duration(milliseconds: 600));
                await page.keyboard.press(Key.enter);
                await Future.delayed(Duration(milliseconds: 500));
                if (debugMode) print('  Added recipient ${i + 1}: ${phoneNumbers[i]}');
              }
            }
          }
        }
      } else {
        // No existing group found, recipients already added above
        if (debugMode) print('  No existing group found, continuing with new group...');
      }

      // Click "Next" button (may need to click twice - once to show group name field, once to skip it)
      for (int clickCount = 0; clickCount < 2; clickCount++) {
        await Future.delayed(Duration(milliseconds: 125));

        final nextClicked = await page.evaluate('''() => {
          const selectors = [
            '[data-e2e-next-button]',
            'button[aria-label*="Next"]',
            '[data-e2e-next-button=""]',
          ];

          for (const selector of selectors) {
            const btn = document.querySelector(selector);
            if (btn) {
              btn.click();
              return selector;
            }
          }
          return null;
        }''');

        if (nextClicked != null) {
          if (debugMode) print('  Clicked Next button (${clickCount + 1}/2): $nextClicked');
          await Future.delayed(Duration(milliseconds: 350));
        }
      }

      // Wait for the message input screen to load after clicking Next twice
      await Future.delayed(Duration(milliseconds: 500));
    } else {
      // Single recipient - use regular flow
      if (debugMode) print('  Single recipient, typing number...');
      await page.keyboard.type(phoneNumbers[0], delay: Duration(milliseconds: 50));

      // Wait for autocomplete to appear
      if (debugMode) print('  Waiting for autocomplete...');
      await Future.delayed(Duration(milliseconds: 1500));

      // Press Down arrow to select from autocomplete, then Enter
      if (debugMode) print('  Selecting from autocomplete...');
      await page.keyboard.press(Key.arrowDown);
      await Future.delayed(Duration(milliseconds: 125));
      await page.keyboard.press(Key.enter);

      // Wait for conversation to open
      if (debugMode) print('  Waiting for conversation to open...');
      await Future.delayed(Duration(milliseconds: 1500)); // Increased wait time
      if (debugMode) print('  Conversation should be open...');
    }

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
        if (debugMode) print('  Checking for message field: $selector');
        await page.waitForSelector(selector, timeout: Duration(seconds: 15));
        messageFieldSelector = selector;
        messageFieldFound = true;
        if (debugMode) print('  ✓ Found message field: $selector');
        await Future.delayed(Duration(milliseconds:125));
        break;
      } catch (e) {
        if (debugMode) print('  ✗ Not found: $selector');
        continue;
      }
    }

    if (!messageFieldFound || messageFieldSelector == null) {
      throw Exception('Could not find message field');
    }

    // Click the message field to focus it first (always do this)
    final field = await page.$(messageFieldSelector);
    if (field != null) {
      await field.click();
      await Future.delayed(Duration(milliseconds: 125));
    }

    // Insert message text FIRST if provided (before image)
    if (messageText != null && messageText.isNotEmpty) {
      if (debugMode) print('  Copying message text to clipboard and pasting...');

      // First, copy text to clipboard
      await page.evaluate('''(text) => {
        return navigator.clipboard.writeText(text);
      }''', args: [messageText]);

      // Wait a moment for clipboard to be set
      await Future.delayed(Duration(milliseconds: 75));

      // Ensure the field is focused
      final field = await page.$(messageFieldSelector);
      if (field != null) {

        await page.keyboard.down(Key.shift);
        await page.keyboard.press(Key.insert);
        await page.keyboard.up(Key.shift);
      }
    }

    // Attach image AFTER text if provided
    if (imagePath != null) {
      if (debugMode) print('  Attaching image via file input...');

      // Try to find and use the file input element
      final fileInputFound = await page.evaluate('''() => {
        // Look for the file input (usually hidden)
        const fileInput = document.querySelector('input[type="file"]') ||
                         document.querySelector('[data-e2e-attach-media-button]');
        if (fileInput) {
          return true;
        }
        return false;
      }''');

      if (fileInputFound) {
        // Use the file input directly
        final fileInput = await page.$('input[type="file"]');
        if (fileInput != null) {
          await fileInput.uploadFile([File(imagePath)]);
          if (debugMode) print('  Image uploaded via file input');
          await Future.delayed(Duration(milliseconds: 750));
        }
      } else {
        // Fallback to drop/paste method
        if (debugMode) print('  File input not found, using drop/paste method...');
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
        if (debugMode) print('  Image attached via drop/paste, waiting for processing...');
        await Future.delayed(Duration(milliseconds: 1250)); // Increased wait time for image to fully load
      }

      // Debug: Check if image was actually attached
      if (debugMode) {
        final imageAttached = await page.evaluate('''() => {
          const imgs = document.querySelectorAll('img[src*="blob:"], img[src*="data:"]');
          const attachments = document.querySelectorAll('[data-e2e-message-attachment]');
          return {
            blobImages: imgs.length,
            attachments: attachments.length
          };
        }''');
        print('  Debug - Image attachment check: $imageAttached');
      }
    }

    // Wait a moment to ensure both text and image are in the compose area
    if (imagePath != null && messageText != null) {
      if (debugMode) print('  Waiting for text and image to be ready...');
      await Future.delayed(Duration(milliseconds: 350));
    }

    // Debug: Check what's in the compose area
    if (debugMode) {
      final composeContent = await page.evaluate('''() => {
        const messageField = document.querySelector('[data-e2e-message-input-box]') ||
                            document.querySelector('div[contenteditable="true"]') ||
                            document.querySelector('[role="textbox"]');
        if (messageField) {
          return {
            text: messageField.textContent || messageField.innerText,
            html: messageField.innerHTML,
            childNodes: messageField.childNodes.length
          };
        }
        return null;
      }''');
      print('  Debug - Compose area content: $composeContent');

      // Also check for send button state
      final sendButtonState = await page.evaluate('''() => {
        const sendBtn = document.querySelector('[data-e2e-send-button]') ||
                       document.querySelector('[aria-label*="Send"]');
        if (sendBtn) {
          return {
            disabled: sendBtn.disabled,
            ariaDisabled: sendBtn.getAttribute('aria-disabled'),
            classes: sendBtn.className
          };
        }
        return null;
      }''');
      print('  Debug - Send button state: $sendButtonState');
    }

    // Send
    if (debugMode) print('  Pressing Enter to send...');
    await page.keyboard.press(Key.enter);

    // Wait for message to be sent and verify
    await Future.delayed(Duration(milliseconds: 1500)); // Increased wait time for sending

    // Debug: Take screenshot after send attempt
    if (debugMode) {
      try {
        await page.screenshot();
        print('  Debug - Screenshot taken');
      } catch (e) {
        print('  Debug - Could not take screenshot: $e');
      }
    }

    // Check for confirmation: wait for div with class "text-msg msg-content" containing the sent text
    if (messageText != null && messageText.isNotEmpty) {
      final verified = await waitForMessageConfirmation(page, messageText, debugMode);
      if (!verified) {
        // One more check - see if the compose field is empty (indicates message was sent)
        final fieldEmpty = await page.evaluate('''() => {
          const messageField = document.querySelector('[data-e2e-message-input-box]') ||
                              document.querySelector('div[contenteditable="true"]') ||
                              document.querySelector('[role="textbox"]');
          if (messageField) {
            const isEmpty = !messageField.textContent || messageField.textContent.trim() === '';
            return isEmpty;
          }
          return false;
        }''');

        if (debugMode) print('    Debug: Compose field empty = $fieldEmpty');

        if (fieldEmpty != true) {
          throw Exception('Message confirmation not found and compose field not empty - send likely failed');
        } else {
          if (debugMode) print('    Debug: Compose field is empty, assuming message was sent');
        }
      }
    } else {
      // For image-only messages, just wait a bit longer
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Navigate back to main screen for next message
    await page.goto('https://messages.google.com/web',
      wait: Until.domContentLoaded,
      timeout: Duration(seconds: 30));

    // Wait for start chat button again
    await page.waitForSelector(startChatSelector, timeout: Duration(seconds: 10));
              await Future.delayed(Duration(milliseconds: 125));

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
    // Wait up to 7 seconds for the message to appear in the conversation
    final timeout = DateTime.now().add(Duration(seconds: 7));

    // Extract first line of message for easier matching
    final firstLine = messageText.split('\n')[0];
    if (debugMode) print('    Debug: Looking for message starting with: "$firstLine"');

    while (DateTime.now().isBefore(timeout)) {
      // Look for the sent message in multiple ways
      final found = await page.evaluate('''(firstLine) => {
        // Try multiple selectors for sent messages
        const selectors = [
          '.text-msg.msg-content',
          '[data-e2e-message-text]',
          '.message-text',
          '[class*="message"]',
        ];

        for (const selector of selectors) {
          const messageDivs = document.querySelectorAll(selector);
          for (let div of messageDivs) {
            const text = div.textContent || div.innerText;
            if (text && text.includes(firstLine)) {
              return true;
            }
          }
        }

        // Also check if the compose field is now empty (indicates message was sent)
        const composeField = document.querySelector('[data-e2e-message-input-box]') ||
                            document.querySelector('div[contenteditable="true"]') ||
                            document.querySelector('[role="textbox"]');
        if (composeField) {
          const isEmpty = !composeField.textContent || composeField.textContent.trim() === '';
          if (isEmpty) {
            return true; // Field is empty, message likely sent
          }
        }

        return false;
      }''', args: [firstLine]);

      if (found == true) {
        if (debugMode) print('    Debug: Message confirmation found');
        return true;
      }

      await Future.delayed(Duration(milliseconds: 125));
    }

    if (debugMode) print('    Debug: Message confirmation NOT found after timeout');
    return false;

  } catch (e) {
    if (debugMode) print('    Debug: waitForMessageConfirmation error: $e');
    return false;
  }
}
