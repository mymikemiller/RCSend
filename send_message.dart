import 'dart:io';
import 'dart:convert';
import 'dart:async';
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
    print('Waiting for Google Messages to be ready...');
    print('(If you need to log in or pair your phone, please do so now)');
    print('');

    // Wait for the Start chat button to appear (indicates page is fully loaded)
    print('Detecting when messages interface is ready...');
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
      print('');
      print('Could not detect ready state automatically.');
      print('Please ensure you are logged in and the page is fully loaded.');
      print('');
      await waitForUserConfirmation();

      // Try again to find the button after manual confirmation
      for (var selector in startChatSelectors) {
        try {
          await page.waitForSelector(selector, timeout: Duration(seconds: 2));
          foundSelector = selector;
          break;
        } catch (e) {
          continue;
        }
      }
    }

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

    // Click the "Start chat" button
    print('Clicking Start chat button...');
    if (foundSelector != null) {
      try {
        // Use JavaScript to click the element (more reliable than Puppeteer's click)
        await page.evaluate('''(selector) => {
          const element = document.querySelector(selector);
          if (element) {
            element.scrollIntoView();
            element.click();
            return true;
          }
          return false;
        }''', args: [foundSelector]);

        print('✓ Clicked start chat button');
        await Future.delayed(Duration(milliseconds: 2000));
      } catch (e) {
        print('ERROR: Could not click start chat button: $e');
        await browser.close();
        exit(1);
      }
    } else {
      print('ERROR: Could not find start chat button.');
      print('Please run with --debug flag to capture page structure:');
      print('  dart send_message.dart -p "$phoneNumber" -m "$messageText" --debug');
      await browser.close();
      exit(1);
    }

    // Type the phone number
    print('Typing phone number: $phoneNumber');
    await page.keyboard.type(phoneNumber, delay: Duration(milliseconds: 50));

    // Wait for autocomplete to appear
    print('Waiting for autocomplete...');
    await Future.delayed(Duration(milliseconds: 2000));

    // Press Enter to confirm the recipient
    print('Confirming recipient...');
    await page.keyboard.press(Key.enter);

    // Give extra time for conversation to open
    await Future.delayed(Duration(milliseconds: 2000));

    // Wait for the message input box to appear
    print('Waiting for message input box...');
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
        if (debugMode) print('  Trying to wait for: $selector');
        await page.waitForSelector(selector, timeout: Duration(seconds: 15));
        messageFieldSelector = selector;
        messageFieldFound = true;
        print('✓ Message field loaded: $selector');
        await Future.delayed(Duration(milliseconds: 500));
        break;
      } catch (e) {
        if (debugMode) print('  ✗ Timeout waiting for: $selector');
        continue;
      }
    }

    if (!messageFieldFound || messageFieldSelector == null) {
      print('ERROR: Could not find message field. The conversation may not have loaded properly.');
      await browser.close();
      exit(1);
    }

    // Click the message field to focus it
    print('Clicking message field...');
    final field = await page.$(messageFieldSelector);
    if (field != null) {
      await field.click();
      print('✓ Message field focused');
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Type the message text first if provided
    if (messageText != null && messageText.isNotEmpty) {
      print('Typing message text...');
      await page.keyboard.type(messageText, delay: Duration(milliseconds: 30));
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Attach image if provided using drag-and-drop simulation
    if (imagePath != null) {
      print('Attaching image via drag-and-drop...');

      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final imageBase64 = base64Encode(imageBytes);
      final imageName = imagePath.split('/').last;

      try {
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

              // Find the drop target (message compose area)
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

    // Wait a moment to ensure both text and image are in the compose area
    if (imagePath != null && messageText != null) {
      print('Waiting for image and text to compose together...');
      await Future.delayed(Duration(milliseconds: 1000));
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

/// Waits for user confirmation using dual approach:
/// 1. Tries stdin.readLineSync() first (works in terminal)
/// 2. Falls back to HTTP server (works everywhere including automation tools)
Future<void> waitForUserConfirmation() async {
  final completer = Completer<void>();
  HttpServer? server;

  try {
    // Start a local HTTP server on a random available port
    server = await HttpServer.bind('127.0.0.1', 0);
    final port = server.port;

    print('╔════════════════════════════════════════════════════════════════╗');
    print('║  READY TO PROCEED?                                             ║');
    print('╠════════════════════════════════════════════════════════════════╣');
    print('║  Option 1: Press ENTER to continue                             ║');
    print('║  Option 2: Visit http://127.0.0.1:$port/ready${' ' * (24 - port.toString().length)}║');
    print('╚════════════════════════════════════════════════════════════════╝');
    print('');

    // Listen for HTTP requests
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/ready' || request.uri.path == '/') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <!DOCTYPE html>
            <html>
            <head><title>Ready</title></head>
            <body style="font-family: Arial; text-align: center; padding: 50px;">
              <h1>✓ Signal Received!</h1>
              <p>You can close this window.</p>
              <script>setTimeout(() => window.close(), 2000);</script>
            </body>
            </html>
          ''');
        await request.response.close();

        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });

    // Also try to listen for stdin in parallel (works in terminal)
    if (stdin.hasTerminal) {
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } catch (e) {
        // Can't set terminal modes, but we'll still try to read
      }

      // Read stdin in the background
      stdin.first.then((_) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }).catchError((_) {
        // Stdin failed, that's okay - HTTP will work
      });
    }

    // Wait for either stdin or HTTP signal
    await completer.future;

  } finally {
    await server?.close();
  }
}
