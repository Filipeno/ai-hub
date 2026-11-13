@echo off
rem perplexity-app login            one-time sign-in window (your Perplexity account)
rem perplexity-app ask --task "..." --out file    send one question to Perplexity (Search mode) in a hidden Chrome
if /i "%~1"=="login" goto login
if /i "%~1"=="ask" goto ask
echo Usage: perplexity-app login ^| perplexity-app ask --task "..." --out file [--drive] [--file path]
exit /b 2
:login
node "%~dp0..\perplexity-app\login.mjs"
exit /b %errorlevel%
:ask
node "%~dp0..\perplexity-app\ask.mjs" %2 %3 %4 %5 %6 %7 %8 %9
exit /b %errorlevel%
