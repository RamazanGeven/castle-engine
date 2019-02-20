{
  Copyright 2018 Benedikt Magnus.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Cross-platform recognition of the system language/locale. }
unit CastleSystemLanguage;

{$I castleconf.inc}

interface

uses GetText;

const
  SystemDefaultLanguage = 'en';
  SystemDefaultLocale = 'en_US';

{ Returns the language code of the system language. See SystemDefaultLanguage. }
function SystemLanguage(const ADefaultLanguage: String = SystemDefaultLanguage): String; inline;
{ Returns the locale code of the system locale. See SystemDefaultLocale. }
function SystemLocale(const ADefaultLocale: String = SystemDefaultLocale): String; inline;

implementation

uses CastleAndroidNativeAppGlue;

function SystemLanguage(const ADefaultLanguage: String = SystemDefaultLanguage): String;
begin
  Result := SystemLocale(ADefaultLanguage);
  Delete(Result, 3, Length(Result)); //Removes the locale info behind the language code.
end;

function SystemLocale(const ADefaultLocale: String = SystemDefaultLocale): String;
{$ifndef ANDROID}
var
  TempDefaultLocale: String;
{$endif}
begin
  {$ifdef ANDROID}
    Result := AndroidLanguage + '_' + AndroidCountry;
  {$else}
    TempDefaultLocale := ADefaultLocale; //Because GetLanguageIDs, whyever, the default language as var parameter...
    GetLanguageIDs(Result, TempDefaultLocale);
  {$endif}

  if Result = '' then
    Result := ADefaultLocale
  else
    Delete(Result, 6, Length(Result)); //There can be more than the language code and the locale info in the result string.
                                       //For example, on Debian based systems there can be the encoding as suffix. ("en_GB.UTF-8")
                                       //So if we really only want the langauge code and the locale info, we have to delete everything behind it.
end;

end.
