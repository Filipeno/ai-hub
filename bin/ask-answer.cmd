@echo off
rem ask-answer <id> "<answer>"   answer a helper's question (ids are in <hub>\inbox\claude\) and rerun the job
if "%~2"=="" ( echo Usage: ask-answer ^<id^> "^<answer^>" & exit /b 2 )
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0ask.ps1" -AnswerId "%~1" -Answer "%~2"
exit /b %errorlevel%
