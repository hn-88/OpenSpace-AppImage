/*****************************************************************************************
 *                                                                                       *
 * GHOUL                                                                                 *
 * General Helpful Open Utility Library                                                  *
 *                                                                                       *
 * Copyright (c) 2012-2025                                                               *
 *                                                                                       *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this  *
 * software and associated documentation files (the "Software"), to deal in the Software *
 * without restriction, including without limitation the rights to use, copy, modify,    *
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to    *
 * permit persons to whom the Software is furnished to do so, subject to the following   *
 * conditions:                                                                           *
 *                                                                                       *
 * The above copyright notice and this permission notice shall be included in all copies *
 * or substantial portions of the Software.                                              *
 *                                                                                       *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,   *
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A         *
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT    *
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF  *
 * CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE  *
 * OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                                         *
 ****************************************************************************************/

#include <ghoul/misc/clipboard.h>

#include <ghoul/misc/exception.h>
#include <ghoul/format.h>
#include <algorithm>
#include <sstream>

#ifdef WIN32
#include <Windows.h>
#elif defined(__APPLE__)
#else
#include <X11/Xlib.h>
#include <string>
#include <limits.h>
#include <iostream>
#endif

namespace {
#ifndef WIN32
   // This is called with a specific input, but has the potential to be very dangerous
    bool exec(const std::string& cmd, std::string& value) {
        FILE* pipe = popen(cmd.c_str(), "r");
        if (!pipe) {
            return false;
        }

        constexpr int BufferSize = 1024;
        std::array<char, BufferSize> buffer = {};
        value.clear();
        while (!feof(pipe)) {
            if (fgets(buffer.data(), BufferSize, pipe) != nullptr) {
                value += buffer.data();
            }
        }
        pclose(pipe);
        return true;
    }
#endif

#ifdef __linux__
static bool GetSelection(Display *display, Window window, const char *bufname, const char *fmtname, std::string &out)
{
    unsigned char *result;
    unsigned long ressize, restail;
    int resbits;
    Atom bufid = XInternAtom(display, bufname, False);
    Atom fmtid = XInternAtom(display, fmtname, False);
    Atom propid = XInternAtom(display, "XSEL_DATA", False);
    Atom incrid = XInternAtom(display, "INCR", False);
    XEvent event;

    XSelectInput(display, window, PropertyChangeMask);
    XConvertSelection(display, bufid, fmtid, propid, window, CurrentTime);

    // Wait for SelectionNotify event
    do {
        XNextEvent(display, &event);
    } while (event.type != SelectionNotify || event.xselection.selection != bufid);

    if (event.xselection.property)
    {
        XGetWindowProperty(display, window, propid, 0, LONG_MAX / 4, True,
                           AnyPropertyType, &fmtid, &resbits, &ressize, &restail, &result);

        if (fmtid != incrid)
            out.append(reinterpret_cast<char*>(result), ressize);

        XFree(result);

        if (fmtid == incrid)
        {
            do {
                do {
                    XNextEvent(display, &event);
                } while (event.type != PropertyNotify || event.xproperty.atom != propid || event.xproperty.state != PropertyNewValue);

                XGetWindowProperty(display, window, propid, 0, LONG_MAX / 4, True,
                                   AnyPropertyType, &fmtid, &resbits, &ressize, &restail, &result);

                out.append(reinterpret_cast<char*>(result), ressize);
                XFree(result);
            } while (ressize > 0);
        }
        return true;
    }
    return false;
}

std::string getClipboardTextX11()
{
    std::string text;
    Display *display = XOpenDisplay(nullptr);
    if (!display)
        return text;

    unsigned long color = BlackPixel(display, DefaultScreen(display));
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                        0, 0, 1, 1, 0, color, color);

    bool success = GetSelection(display, window, "CLIPBOARD", "UTF8_STRING", text) ||
                   GetSelection(display, window, "CLIPBOARD", "STRING", text);

    XDestroyWindow(display, window);
    XCloseDisplay(display);

    return success ? text : std::string();
}
#endif

} // namespace

namespace ghoul {

std::string clipboardText() {
   // debug
   std::cerr << "Entered clipboardText()" << std::endl;
#ifdef WIN32
    // Try opening the clipboard
    if (!OpenClipboard(nullptr)) {
        return "";
    }

    // Get handle of clipboard object for ANSI text
    HANDLE hData = GetClipboardData(CF_TEXT);
    if (!hData) {
        return "";
    }

    // Lock the handle to get the actual text pointer
    char* pszText = static_cast<char*>(GlobalLock(hData));
    if (!pszText) {
        return "";
    }

    // Save text in a string class instance
    std::string text(pszText);

    // Release the lock
    GlobalUnlock(hData);

    // Release the clipboard
    CloseClipboard();

    text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
    return text;
#elif defined(__APPLE__)
    std::string text;
    if (exec("pbpaste", text)) {
        return text.substr(0, text.length()); // remove a line ending
    }
    return "";
#else
    return getClipboardTextX11();
#endif
}

void setClipboardText(const std::string& text) {
#ifdef WIN32
    HANDLE hData = GlobalAlloc(GMEM_MOVEABLE | GMEM_DDESHARE, text.length() + 1);
    if (!hData) {
        throw RuntimeError("Error allocating memory", "Clipboard");
    }

    char* ptrData = static_cast<char*>(GlobalLock(hData));
    if (!ptrData) {
        GlobalFree(hData);
        throw RuntimeError("Error acquiring lock", "Clipboard");
    }
    std::memcpy(ptrData, text.c_str(), text.length() + 1);

    GlobalUnlock(hData);

    if (!OpenClipboard(nullptr)) {
        throw RuntimeError("Error opening clipboard", "Clipboard");
    }

    if (!EmptyClipboard()) {
        throw RuntimeError("Error cleaning clipboard", "Clipboard");
    }

    SetClipboardData(CF_TEXT, hData);
    CloseClipboard();
#elif defined(__APPLE__)
    std::string buf;
    bool success = exec(std::format("echo \"{}\" | pbcopy", text), buf);
    if (!success) {
        throw RuntimeError("Error setting text to clipboard", "Clipboard");
    }
#else
    std::string buf;
    const bool success = exec(std::format("echo \"{}\" | xclip -i -sel c -f", text), buf);
    if (!success) {
        throw RuntimeError("Error setting text to clipboard", "Clipboard");
    }
#endif
}

} // namespace ghoul
