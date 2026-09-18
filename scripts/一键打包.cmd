@echo off
chcp 65001 >nul
title JiZi - build IPA on GitHub Actions
echo.
echo   ============================================
echo    JiZi  -  build IPA on GitHub Actions
echo   ============================================
echo.
echo   Token:  https://github.com/settings/tokens
echo           -^> Tokens (classic) -^> Generate new token (classic)
echo           check [repo] + [workflow],  expiry 7 days
echo.
set /p U=GitHub username: 
set /p T=GitHub token   : 
if "%U%"=="" (echo. & echo   username is empty, abort. & pause & exit /b 1)
if "%T%"=="" (echo. & echo   token is empty, abort.    & pause & exit /b 1)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0push-to-github.ps1" -User "%U%" -Token "%T%"
echo.
echo   ---- done ----
pause
