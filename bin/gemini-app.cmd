@echo off
rem gemini-app login            one-time sign-in window (your Google account with the AI Plus plan)
rem gemini-app ask --task "..." --out file    send one prompt to the Gemini app in a hidden Chrome
if /i "%~1"=="login" goto login
if /i "%~1"=="ask" goto ask
echo Usage: gemini-app login ^| gemini-app ask --task "..." --out file
exit /b 2
:login
node "%~dp0..\gemini-app\login.mjs"
exit /b %errorlevel%
:ask
node "%~dp0..\gemini-app\ask.mjs" %2 %3 %4 %5 %6 %7 %8 %9
exit /b %errorlevel%
