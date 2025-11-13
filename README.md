# RCSend - Google Messages Automation

A Dart script that uses Puppeteer to automate sending text messages through Google Messages Web (messages.google.com).

## Prerequisites

- Dart SDK 3.0 or higher
- Google Messages Web paired with your phone

## Installation

1. Install dependencies:
```bash
dart pub get
```

## Usage

```bash
dart send_message.dart -p <phone_number> -m <message> [-i <image_path>]
```

### Arguments

- `-p, --phone`: Phone number to send the message to (required)
- `-m, --message`: Message text to send (required)
- `-i, --image`: Path to image file to attach (optional)
- `-d, --debug`: Enable debug mode for troubleshooting (optional)
- `-h, --help`: Show help message

### Examples

```bash
# Send a simple text message
dart send_message.dart -p "555-123-4567" -m "Hello from Dart!"

# Send a message with an image
dart send_message.dart -p "+15551234567" -m "Check out this photo!" -i "/path/to/image.jpg"

# Send with debug mode enabled
dart send_message.dart -p "555-123-4567" -m "Test message" --debug
```

## How It Works

1. The script launches a Chromium browser in non-headless mode
2. Navigates to messages.google.com
3. Waits for you to log in (first time only - session is persisted)
4. Automatically clicks the "Start chat" button
5. Types the phone number and confirms the recipient
6. Attaches image if provided (via `-i` flag)
7. Types the message text
8. Sends the message with Ctrl+Enter
9. Closes the browser

## Notes

- The browser runs in **visible mode** (not headless) so you can complete the login process
- Login session is saved in the `./user_data` directory, so you only need to log in once
- Only need to press ENTER once after logging in - everything else is automated
- Phone numbers can be in any format (e.g., "555-123-4567", "+15551234567", etc.)
- Make sure Google Messages Web is already paired with your phone before running
- **Image attachments are experimental** - the script attempts to inject a file input and trigger paste events, but Google Messages Web may have security restrictions that prevent automated file uploads. For reliable image sending, consider manually attaching images.

## Troubleshooting

**Login timeout**: If you see a timeout error, make sure you complete the login process within 2 minutes.

**Selectors not found**: Google may update their web interface. The script uses common selectors that may need updating.

**Message not sending**: Ensure your Google Messages Web is properly paired with your phone and has an active connection.
