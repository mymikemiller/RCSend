import 'dart:io';
import 'dart:convert';
import 'package:puppeteer/puppeteer.dart';
import 'package:args/args.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('phone', abbr: 'p', help: 'Phone number to send message to', mandatory: true)
    ..addOption('message', abbr: 'm', help: 'Message text to send (optional if -i is provided)')
    ..addOption('image', abbr: 'i', help: 'Path to image file to attach')
    ..addFlag('help', abbr: 'h', help: 'Show this help message', negatable: false)
    ..addFlag('debug', abbr: 'd', help: 'Enable debug mode', negatable: false);

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    print('Error parsing arguments: $e\n');
    print(parser.usage);
    exit(1);
  }

  if (argResults['help'] as bool) {
    print('Usage: dart send_message_v2.dart -p <phone_number> -m <message>');
    print(parser.usage);
    exit(0);
  }

  final phoneNumber = argResults['phone'] as String;
  final messageText = argResults['message'] as String?;
  final imagePath = argResults['image'] as String?;
  final debugMode = argResults['debug'] as bool;

  // Validate that at least one of message or image is provided
  if (messageText == null && imagePath == null) {
    print('Error: Must provide either -m (message) or -i (image), or both');
    print('');
    print(parser.usage);
    exit(1);
  }

  // Validate image path if provided
  if (imagePath != null) {
    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) {
      print('Error: Image file not found at: $imagePath');
      exit(1);
    }
    print('Image to attach: $imagePath');
  }

  print('Starting browser automation...');
  print('');

  // Launch browser with a persistent user data directory to maintain login
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

    print('');
    print('╔═══════════════════════════════════════════════════════════════╗');
    print('║  BROWSER OPENED - COMPLETE SETUP BEFORE CONTINUING            ║');
    print('╠═══════════════════════════════════════════════════════════════╣');
    print('║  Take your time to:                                           ║');
    print('║  1. Log in to your Google account if needed                   ║');
    print('║  2. Pair with your phone using the QR code if needed          ║');
    print('║  3. Wait for ALL messages to load completely                  ║');
    print('║  4. Verify you can see the "Start chat" button                ║');
    print('║                                                                ║');
    print('║  The browser will stay open - take as long as you need!       ║');
    print('║  ONLY press ENTER when the page is fully ready!               ║');
    print('╚═══════════════════════════════════════════════════════════════╝');
    print('');
    print('Press ENTER when ready to proceed with automation...');

    stdin.readLineSync();

    print('Proceeding with automation...');
    print('');

    if (debugMode) {
      print('DEBUG MODE: Saving page HTML to debug.html...');
      final html = await page.content ?? '';
      await File('debug.html').writeAsString(html);
      print('HTML saved. Looking for buttons...');

      // Find all buttons and links
      final buttons = await page.$$('button');
      print('Found ${buttons.length} buttons');

      final links = await page.$$('a');
      print('Found ${links.length} links');

      print('\nPress ENTER to continue...');
      stdin.readLineSync();
    }

    // Try to click the "Start chat" button
    print('Looking for Start chat button...');
    bool chatStarted = false;

    // Try multiple selectors for the start chat button
    final startChatSelectors = [
      'a[href="#new"]',
      'button[mattooltip="Start chat"]',
      'button[aria-label="Start chat"]',
      'mw-fab-speed-dial button',
      'mw-fab-speed-dial-trigger',
      '[class*="fab"]',
      'a[aria-label*="Start"]',
      'button[aria-label*="Start"]',
      '[data-e2e-start-chat]',
      'mw-start-chat-fab',
    ];

    for (var selector in startChatSelectors) {
      try {
        if (debugMode) print('Trying selector: $selector');
        await page.waitForSelector(selector, timeout: Duration(seconds: 2));
        await page.click(selector);
        print('✓ Clicked start chat button: $selector');
        chatStarted = true;
        await Future.delayed(Duration(milliseconds: 1500));
        break;
      } catch (e) {
        if (debugMode) print('  ✗ Selector not found: $selector');
        continue;
      }
    }

    if (!chatStarted) {
      print('ERROR: Could not find start chat button automatically.');
      print('Please run with --debug flag to capture page structure:');
      print('  dart send_message.dart -p "$phoneNumber" -m "$messageText" --debug');
      await browser.close();
      exit(1);
    }

    // Type the phone number
    print('Typing phone number: $phoneNumber');
    await page.keyboard.type(phoneNumber, delay: Duration(milliseconds: 50));
    await Future.delayed(Duration(milliseconds: 1000));

    // Press Enter to confirm the recipient
    print('Confirming recipient...');
    await page.keyboard.press(Key.enter);

    // Wait longer for the conversation to load
    // After pressing Enter, Google Messages opens the conversation
    // and the focus is already in the message field
    print('Waiting for conversation to load...');
    await Future.delayed(Duration(milliseconds: 2500));

    // Attach image if provided using drag-and-drop simulation
    if (imagePath != null) {
      print('Attaching image via drag-and-drop...');

      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final imageBase64 = base64Encode(imageBytes);
      final imageName = imagePath.split('/').last;

      // Wait a bit for the page to be ready
      await Future.delayed(Duration(milliseconds: 1000));

      try {
        // Find the message input area to drop the image
        final dropTargetSelectors = [
          'div[contenteditable="true"]',
          '[role="textbox"]',
          'mw-message-compose',
          '.compose-container',
        ];

        ElementHandle? dropTarget;
        for (var selector in dropTargetSelectors) {
          try {
            dropTarget = await page.$(selector);
            if (dropTarget != null) {
              if (debugMode) print('  Found drop target: $selector');
              break;
            }
          } catch (e) {
            continue;
          }
        }

        if (dropTarget == null) {
          print('  Warning: Could not find drop target, using document body');
        }

        // Simulate drag-and-drop by triggering drop event with file data
        final scriptWithData = '''
          (async () => {
            const imageBase64 = "$imageBase64";
            const imageName = "$imageName";

            try {
              // Convert base64 to blob
              const response = await fetch('data:image/jpeg;base64,' + imageBase64);
              const blob = await response.blob();
              const file = new File([blob], imageName, { type: blob.type });

              // Find the drop target
              const dropTarget = document.querySelector('[contenteditable="true"]') ||
                                document.querySelector('[role="textbox"]') ||
                                document.body;

              // Create DataTransfer with the file
              const dataTransfer = new DataTransfer();
              dataTransfer.items.add(file);

              // Dispatch drop event
              const dropEvent = new DragEvent('drop', {
                dataTransfer: dataTransfer,
                bubbles: true,
                cancelable: true
              });

              dropTarget.dispatchEvent(dropEvent);

              // Also try paste event as fallback
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

        final success = await page.evaluate(scriptWithData);

        if (success) {
          print('✓ Image drop event triggered, waiting for attachment...');
          await Future.delayed(Duration(milliseconds: 3000));
        } else {
          if (debugMode) print('  Drop event failed, trying alternative method...');

          // Alternative: Try to use file input if available
          final fileInputs = await page.$$('input[type="file"]');
          if (fileInputs.isNotEmpty) {
            await fileInputs[0].uploadFile([imageFile]);
            print('✓ Image attached via file input');
            await Future.delayed(Duration(milliseconds: 2000));
          } else {
            print('Warning: Could not attach image. Continuing...');
          }
        }
      } catch (e) {
        print('Error attaching image: $e');
        if (debugMode) print('Stack trace: ${StackTrace.current}');
      }
    }

    // Type the message if provided
    if (messageText != null && messageText.isNotEmpty) {
      print('Typing message...');
      await page.keyboard.type(messageText, delay: Duration(milliseconds: 30));
      await Future.delayed(Duration(milliseconds: 800));
    }

    // Send with Ctrl+Enter
    print('Sending message (Ctrl+Enter)...');
    await page.keyboard.down(Key.control);
    await page.keyboard.press(Key.enter);
    await page.keyboard.up(Key.control);

    await Future.delayed(Duration(seconds: 2));

    print('');
    print('✓ Message sent successfully!');
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
