//
//  RecognizerManager.m
//  WritePadEN
//
//  Created by Stanislav Miasnikov on 6/4/11.
//  Copyright 2011 PhatWare Corp. All rights reserved.
//

#import "RecognizerManager.h"
#import "RecognizerWrapper.h"
#import "InkWrapper.h"
#import "OptionKeys.h"
#import "NSMutableArray+AddUnique.h"

@interface InkDataManager(Internal)

- (INK_DATA_PTR) dataPtr;

@end

static const UCHR  INTERNET_CHARS[] = 	{'?','!','\"','\'',',','.',':','@','&','$','*','-','=','+','/','\\' };

static RecognizerManager * gManager = nil;

@implementation RecognizedWord

@synthesize word;
@synthesize prob;
@synthesize row;
@synthesize col;
@synthesize isDict;

- (id) init
{
	self = [super init];
	if (self != nil)
	{
        self.isDict = NO;
        self.prob = 0;
        self.word = nil;
	}
	return self;
}

@end


@interface RecognizerManager ()
{
    RECOGNIZER_PTR    _recognizer;
    BOOL _canRealoadRecognizer;
    
    // search for word paramters
    RECOGNIZER_PTR _recognizerSearch;
    NSString * _searchWord;
}

@property (nonatomic, readonly) RECOGNIZER_PTR recognizer;

- (void) initRecognizerForCurrentLanguage;
- (void) freeRecognizerForCurrentLanguage;
- (void) releaseSearchRecognizer;
- (RECOGNIZER_PTR) initSearchInstanceForWord:(NSString *)word;

@end


@implementation RecognizerManager

@synthesize recognizer = _recognizer;

+ (RecognizerManager *) sharedManager
{
	@synchronized(self) 
	{	
		if ( nil == gManager )
		{
			gManager = [[RecognizerManager alloc] init];
		}
	}
	return gManager;
}

+ (int) nextMode:(int)mode
{
    int nextMode = RECMODE_GENERAL;
    switch ( mode )
    {
        case RECMODE_GENERAL :
            nextMode = RECMODE_NUM;
            break;
        case RECMODE_NUM :
            nextMode = RECMODE_CAPS;
            break;
        case RECMODE_CAPS :
            nextMode = RECMODE_WWW;
            break;
        case RECMODE_WWW :
            nextMode = RECMODE_GENERAL;
            break;
    }
    return nextMode;
}

+ (int) calcNextRecognitionMode
{
    NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
    int currentMode = [[RecognizerManager sharedManager] getMode];
    int prevMode = (int)[defaults integerForKey:@"_PreviousRecoMode"];
    int nextMode = RECMODE_GENERAL;
    static NSTimeInterval timeout = 0;
    if ( [[NSDate date] timeIntervalSinceReferenceDate] - timeout > 5.0 )
    {
        if ( currentMode == nextMode )
            nextMode = RECMODE_NUM;
        else if ( currentMode != prevMode )
            nextMode = prevMode;
        [defaults setInteger:currentMode forKey:@"_PreviousRecoMode"];
    }
    else
    {
        nextMode = [RecognizerManager nextMode:currentMode];
        for ( int i = 0; i < 4 && (/*nextMode == prevMode ||*/ nextMode == currentMode); i++ )
        {
            nextMode = [RecognizerManager nextMode:nextMode];
        }
    }
    timeout = [[NSDate date] timeIntervalSinceReferenceDate];
    return nextMode;
}

+ (void) resetRecognizerOptions
{
    NSUserDefaults*	defaults = [NSUserDefaults standardUserDefaults];
    
    if ( ![defaults boolForKey:RecoOptionsSettingsID] )
    {
        // set the default settings for Input Panel
        [defaults setBool:NO  forKey:kRecoOptionsSingleWordOnly];
        [defaults setBool:NO  forKey:kRecoOptionsSeparateLetters];
        [defaults setBool:NO  forKey:kRecoOptionsInternational];
        [defaults setBool:NO  forKey:kRecoOptionsDictOnly];
        [defaults setBool:NO  forKey:kRecoOptionsSuggestDictOnly];
        [defaults setBool:YES forKey:kRecoOptionsSpellIgnoreNum];
        [defaults setBool:YES forKey:kRecoOptionsUseCorrector];
        [defaults setBool:YES forKey:kRecoOptionsUseLearner];
        [defaults setBool:YES forKey:kRecoOptionsAddSpace];
        [defaults setBool:NO  forKey:kRecoOptionsAddSpaceSingleLetter];
        [defaults setBool:YES forKey:kRecoOptionsInsertResult];
        [defaults setBool:NO  forKey:kRecoOptionsAutoInsertResult];
        [defaults setBool:YES forKey:kRecoOptionsSmartPunctuationSpace];
        [defaults setBool:YES  forKey:kRecoOptionsUseDynamicSegment];

        [defaults setBool:YES forKey:kCenterStylusPressure];

        // init default settings
        [defaults setBool:YES forKey:kRecoOptionsSpellIgnoreUpper];
        [defaults setBool:YES forKey:kRecoOptionsUseUserDict];
        [defaults setInteger:3 forKey:kRecoOptionsSymbolRate];

        [defaults setBool:YES forKey:RecoOptionsSettingsID];
        [defaults synchronize];
    }
}

+ (NSString *) stringFromUchr:(CUCHR *)charstring
{
#if HW_RECINT_UNICODE
    // unicode string (UTF-16)
    NSInteger len = 0;
    while( charstring[len] != 0 )
    {
        len++;
        if ( len > 5000 )
            return nil;
    }
    NSString *strText = [[NSString alloc] initWithCharacters:charstring length:len];
#else
    // RecoStringEncoding encoding (cahr *)
    NSString * strText = [[NSString alloc] initWithCString:charstring encoding:RecoStringEncoding];
#endif
    return strText;
}

+ (CUCHR *) uchrFromString:(NSString *)string
{
    if ( [string length] < 1 )
        return NULL;
#if HW_RECINT_UNICODE
    return (CUCHR *)[string cStringUsingEncoding:NSUnicodeStringEncoding];
    //NSInteger len = [string length];
    //UCHR * chars = (UCHR *)malloc( sizeof( UCHR ) * (len + 1) );
    //[string getCharacters:chars range:NSMakeRange( 0, len )];
    //chars[len] = 0;
    //return chars;
#else
    return [string cStringUsingEncoding:RecoStringEncoding];
#endif // HW_RECINT_UNICODE
}

- (id) init
{
	self = [super init];
	if (self != nil) 
	{
        _canRealoadRecognizer = YES;
        _searchWord = nil;
        _recognizerSearch = NULL;
		[self initRecognizerForCurrentLanguage];
    }
	return self;
}

- (void) dealloc
{
    [self freeRecognizerForCurrentLanguage];
}

- (BOOL) reloadSettings
{
    @synchronized(self)
    {
        if ( _canRealoadRecognizer && [self isEnabled] )
        {
            [self initRecognizerForCurrentLanguage];
            return YES;
        }
    }
	return NO;
}


- (BOOL) disable:(BOOL)save
{
	if ( ! [self isEnabled] )
		return NO;
	if ( save )
	{
		[self freeRecognizerForCurrentLanguage];
	}
	else
	{
		HWR_FreeRecognizer( _recognizer, NULL, NULL, NULL );
		_recognizer = NULL;
	}
	return [self isEnabled];
}

- (BOOL) enable
{
	if ( ! [self isEnabled] )
	{
		[self initRecognizerForCurrentLanguage];
	}
	return [self isEnabled];
}

#pragma mark -- search handwriting

- (RECOGNIZER_PTR) initSearchInstanceForWord:(NSString *)word
{
    if ( word == nil || [word length] < 1 )
        return NULL;
    
    if ( NULL != _recognizerSearch )
    {
        if ( [_searchWord length] < 1 || [_searchWord caseInsensitiveCompare:word] != NSOrderedSame )
        {
            HWR_FreeRecognizer( _recognizerSearch, NULL, NULL, NULL );     
            _recognizerSearch = NULL;
            _searchWord = nil;
            
        }
    }
    
    if ( NULL == _recognizerSearch )
    {
        LanguageManager * langManager = [LanguageManager sharedManager];
        
        NSString *	strCorrector = [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
        NSString *	strLearner =  [langManager userFilePathOfType:USERDATA_LEARNER];
        
        _recognizerSearch = HWR_InitRecognizer( NULL, NULL, 
                                                       [strLearner UTF8String], [strCorrector UTF8String], 
                                                       [langManager getLanguageID], NULL );
        if ( _recognizerSearch == NULL )
            return NULL;
        NSUserDefaults*	defaults = [NSUserDefaults standardUserDefaults];
        NSData * data = [defaults dataForKey:[NSString stringWithFormat:@"%@_%d", kRecoOptionsLetterShapes, langManager.currentLanguage]];
        if ( [data length] > 0 )
        {
            HWR_SetLetterShapes( _recognizerSearch, [data bytes] );
        }
        else
        {
            HWR_SetDefaultShapes( _recognizerSearch );
        }
        
        // set recognizer options
        unsigned int	flags = FLAG_USERDICT;
        
        if ( [defaults boolForKey:kRecoOptionsDictOnly] )
            flags |= FLAG_ONLYDICT;
        if ( [defaults boolForKey:kRecoOptionsUseLearner] )
            flags |= FLAG_ANALYZER;		
        if ( [defaults boolForKey:kRecoOptionsUseCorrector] )
            flags |= FLAG_CORRECTOR;
        
        HWR_SetRecognitionFlags( _recognizerSearch, flags );
        _searchWord = [word copy];
        
        const UCHR * pWord = [RecognizerManager uchrFromString:word];
        if ( NULL != pWord )
        {
            HWR_NewUserDict( _recognizerSearch );
            HWR_AddUserWordToDict( _recognizerSearch, pWord, NO );
        }        
        
    }
    return _recognizerSearch;
}

- (BOOL) createUserDictionary
{
    return  HWR_NewUserDict( _recognizer );
}

static int EnumWordsCallback( const UCHR * pszWord, void * pParam )
{
    NSMutableArray * array = (__bridge NSMutableArray *)pParam;
    NSString * sWord = [RecognizerManager stringFromUchr:pszWord];
    [array addObject:sWord];
    return 1;
}

static NSInteger compareUserWords (id a, id b, void *ctx)
{
    NSString * s1 = (NSString *)a;
    NSString * s2 = (NSString *)b;
    return [s1 caseInsensitiveCompare:s2];
}

- (NSArray *) loadUserDictionary
{
    // enumirate user dictionary and add words to array
    NSMutableArray * userWords = [NSMutableArray array];
    int nWords = HWR_EnumUserWords( _recognizer, EnumWordsCallback, (__bridge void *)userWords );
    NSLog(@"%i words added", nWords );
    if ( nWords > 1 )
    {
        [userWords sortUsingFunction:compareUserWords context:(__bridge void *)(self)];
    }
    return [NSArray arrayWithArray:userWords];
}

- (void) releaseSearchRecognizer
{
    _searchWord = nil;
    if ( NULL != _recognizerSearch )
    {
        HWR_FreeRecognizer( _recognizerSearch, NULL, NULL, NULL );     
        _recognizerSearch = NULL;
    }    
}

- (BOOL) findText:(NSString *)text inInk:(InkDataManager *)inkData startFrom:(int)firstStroke selectedOnly:(BOOL)selected
{
    RECOGNIZER_PTR recognizer = [self initSearchInstanceForWord:text];

    HWR_Reset( recognizer );
    
    const UCHR * pText = HWR_RecognizeInkData( recognizer, [inkData dataPtr], firstStroke, -1, FALSE, FALSE, FALSE, selected );

    [inkData selectAllStrokes:NO];

    if ( NULL != pText )
    {
        for ( int word = 0; word < HWR_GetResultWordCount( recognizer ); word++ )
        {
            int altCnt = MIN( 4, HWR_GetResultAlternativeCount( recognizer, word ) );
            for ( int alt = 0; alt < altCnt; alt++ )
            {
                const UCHR * pWord = HWR_GetResultWord( recognizer, word, alt );
                if ( pWord != NULL )
                {
                    NSString *	theWord = [RecognizerManager stringFromUchr:pWord];
                    if ( theWord != nil && [theWord rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound )
                    {
                        // select strokes that belong to the found word
                        int * ids = NULL;
                        int cnt = HWR_GetStrokeIDs( recognizer, word, alt, (const int **)&ids );
                        for ( int i = 0; i < cnt; i++ )
                        {
                            [inkData selectStroke:YES atIndex:firstStroke+ids[i]];
                        }
                        return TRUE;
                    }
                }
            }
        }
    }
    return FALSE;
}

- (BOOL) matchWord:(NSString *)text
{
    int cnt = HWR_GetResultWordCount( _recognizer );
    if ( cnt != 1 )
        return NO;
    int altCnt = MIN( 5, HWR_GetResultAlternativeCount( _recognizer, 0 ) );
    for ( int alt = 0; alt < altCnt; alt++ )
    {
        const UCHR * pWord = HWR_GetResultWord( _recognizer, 0, alt );
        if ( pWord != NULL )
        {
            NSString *	theWord = [RecognizerManager stringFromUchr:pWord];
            if ( theWord != nil && [text caseInsensitiveCompare:theWord] == NSOrderedSame )
                return YES;
        }
    }
    return NO;
}

- (int) getWordCount
{
    int cnt = HWR_GetResultWordCount( _recognizer );
    return cnt;
}

- (int) getAltCount:(int)word
{
    int cnt = HWR_GetResultAlternativeCount( _recognizer, word );
    return cnt;
}

#pragma mark -- Recognizer 


- (void) initRecognizerForCurrentLanguage
{
    NSUserDefaults  * defaults = [NSUserDefaults standardUserDefaults];
    LanguageManager * langManager = [LanguageManager sharedManager];
    [langManager changeCurrentLanguage:(WPLanguage)[[NSUserDefaults standardUserDefaults] integerForKey:kGeneralOptionsCurrentLanguage]];
    
    NSString *	strUserFile  = [langManager userFilePathOfType:USERDATA_DICTIONARY];
    NSString *	strCorrector = [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
    NSString *	strLearner   = [langManager userFilePathOfType:USERDATA_LEARNER];
    NSString *	strMainDict  = [langManager mainDictionaryPath];

	if ( _recognizer == NULL )
    {
        _recognizer = HWR_InitRecognizer( [strMainDict UTF8String], [strUserFile UTF8String], 
                                                       [strLearner UTF8String], [strCorrector UTF8String], 
                                                       [langManager getLanguageID], NULL );
    }
    else
    {
        HWR_ReloadLearner( _recognizer, [strLearner UTF8String] );
        HWR_ReloadUserDict(_recognizer, [strUserFile UTF8String] );
        HWR_ReloadAutoCorrector( _recognizer, [strCorrector UTF8String] );
    }
	if ( NULL == _recognizer )
		return;
    
	NSData * data = [defaults dataForKey:[NSString stringWithFormat:@"%@_%d", kRecoOptionsLetterShapes, langManager.currentLanguage]];
	if ( [data length] > 0 )
	{
		HWR_SetLetterShapes( _recognizer, [data bytes] );
	}
	else
	{
		HWR_SetDefaultShapes( _recognizer );
	}
	
    // set recognizer options
    unsigned int	flags = HWR_GetRecognitionFlags( _recognizer );
    if ( [defaults boolForKey:kRecoOptionsSingleWordOnly] )
        flags |= FLAG_SINGLEWORDONLY;
    else 
        flags &= ~FLAG_SINGLEWORDONLY;
    if ( [defaults boolForKey:kRecoOptionsSeparateLetters] )
        flags |= FLAG_SEPLET;
    else 
        flags &= ~FLAG_SEPLET;
    if ( [defaults boolForKey:kRecoOptionsInternational] )
        flags |= FLAG_INTERNATIONAL;
    else 
        flags &= ~FLAG_INTERNATIONAL;
    if ( [defaults boolForKey:kRecoOptionsDictOnly] )
        flags |= FLAG_ONLYDICT;
    else 
        flags &= ~FLAG_ONLYDICT;
    if ( [defaults boolForKey:kRecoOptionsSuggestDictOnly] )
        flags |= FLAG_SUGGESTONLYDICT;
    else 
        flags &= ~FLAG_SUGGESTONLYDICT;
    if ( [defaults boolForKey:kRecoOptionsUseUserDict] )
        flags |= FLAG_USERDICT;
    else 
        flags &= ~FLAG_USERDICT;
    if ( [defaults boolForKey:kRecoOptionsUseLearner] )
        flags |= FLAG_ANALYZER;
    else 
        flags &= ~FLAG_ANALYZER;
    
    if ( [defaults boolForKey:kRecoOptionsUseCorrector] )
        flags |= FLAG_CORRECTOR;
    else 
        flags &= ~FLAG_CORRECTOR;
    
    if ( [defaults boolForKey:kRecoOptionsSpellIgnoreNum] )
        flags |= FLAG_SPELLIGNORENUM;
    else 
        flags &= ~FLAG_SPELLIGNORENUM;
    
    if ( [defaults boolForKey:kRecoOptionsSpellIgnoreUpper] )
        flags |= FLAG_SPELLIGNOREUPPER;
    else 
        flags &= ~FLAG_SPELLIGNOREUPPER;
    
    if ( [defaults boolForKey:kRecoOptionsUseDynamicSegment] )
        flags &= ~FLAG_STATICSEGMENT;
    else
        flags |= FLAG_STATICSEGMENT;

    flags |= FLAG_SMOOTHSTROKES;
    HWR_SetRecognitionFlags( _recognizer, flags );
}

- (void) freeRecognizerForCurrentLanguage
{
	if ( _recognizer )
	{
		LanguageManager * langManager = [LanguageManager sharedManager];
		NSString *	strUserFile =  [langManager userFilePathOfType:USERDATA_DICTIONARY];
		NSString *	strCorrector =  [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
		NSString *	strLearner =  [langManager userFilePathOfType:USERDATA_LEARNER];
		
		HWR_FreeRecognizer( _recognizer, [strUserFile UTF8String], [strLearner UTF8String], [strCorrector UTF8String] );
		_recognizer = NULL;
	}
    [self releaseSearchRecognizer];
}


- (void) saveRecognizerDataOfType:(NSInteger)type
{
	LanguageManager * langManager = [LanguageManager sharedManager];
	if ( 0 != (type & USERDATA_AUTOCORRECTOR) )
	{
		NSString *	strCorrector =  [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
		HWR_SaveWordList( _recognizer, [strCorrector UTF8String] );	
	}
	if ( 0 != (type & USERDATA_LEARNER) )
	{
		NSString *	strLearner =  [langManager userFilePathOfType:USERDATA_LEARNER];
		HWR_SaveLearner( _recognizer, [strLearner UTF8String] );	
	}
	if ( 0 != (type & USERDATA_DICTIONARY) || type == 0 )
	{
		NSString *	strUserFile =  [langManager userFilePathOfType:USERDATA_DICTIONARY];
		HWR_SaveUserDict( _recognizer, [strUserFile UTF8String] );	
	}
}

- (void) resetRecognizerDataOfType:(NSInteger)type
{
	LanguageManager * langManager = [LanguageManager sharedManager];
	if ( 0 != (type & USERDATA_AUTOCORRECTOR) )
	{
		NSString *	strCorrector =  [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
		HWR_ResetAutoCorrector( _recognizer, [strCorrector UTF8String] );
	}
	if ( 0 != (type & USERDATA_LEARNER) )
	{
		NSString *	strLearner =  [langManager userFilePathOfType:USERDATA_LEARNER];
		HWR_ResetLearner( _recognizer, [strLearner UTF8String] );
	}
	if ( 0 != (type & USERDATA_DICTIONARY) || type == 0 )
	{
		NSString *	strUserFile =  [langManager userFilePathOfType:USERDATA_DICTIONARY];
		HWR_ResetUserDict( _recognizer, [strUserFile UTF8String] );	
	}
}

- (void) reloadRecognizerDataOfType:(NSInteger)type
{
	LanguageManager * langManager = [LanguageManager sharedManager];
	if ( 0 != (type & USERDATA_AUTOCORRECTOR) )
	{
		NSString *	strCorrector =  [langManager userFilePathOfType:USERDATA_AUTOCORRECTOR];
		HWR_ReloadAutoCorrector( _recognizer, [strCorrector UTF8String] );
	}
	if ( 0 != (type & USERDATA_LEARNER) )
	{
		NSString *	strLearner =  [langManager userFilePathOfType:USERDATA_LEARNER];
		HWR_ReloadLearner( _recognizer, [strLearner UTF8String] );
	}
	if ( 0 != (type & USERDATA_DICTIONARY) || type == 0 )
	{
		NSString *	strUserFile =  [langManager userFilePathOfType:USERDATA_DICTIONARY];
		HWR_ReloadUserDict( _recognizer, [strUserFile UTF8String] );	
	}
}

- (void) reset
{
	if ( _recognizer )
    {
		HWR_Reset( _recognizer );
    }
}

- (void) setMode:(int)mode
{
	if ( NULL == _recognizer )
		return;
	if ( mode == RECMODE_WWW )
		HWR_SetCustomCharset( _recognizer, NULL, INTERNET_CHARS );
	else
		HWR_SetCustomCharset( _recognizer, NULL, NULL );				
	HWR_SetRecognitionMode( _recognizer, mode );
}

- (int) getMode
{
	return HWR_GetRecognitionMode( _recognizer );
}

- (BOOL) isEnabled
{
	return (_recognizer != NULL);
}

- (void) modifyRecoFlags:(NSUInteger)addFlags deleteFlags:(NSUInteger)delFlags
{
	if ( NULL != _recognizer )
	{
		unsigned int	flags = HWR_GetRecognitionFlags( _recognizer );
		if ( 0 != delFlags )
			flags &= ~delFlags;
		if ( 0 != addFlags )
			flags |= addFlags;
		HWR_SetRecognitionFlags( _recognizer, flags );
	}	
}

- (NSString *) recognizeInkData:(InkDataManager *)inkData background:(BOOL)backgroundReco async:(BOOL)asyncReco flipY:(BOOL)flip selection:(BOOL)selection
{
	const UCHR * pText = NULL;
	if ( ! [self isEnabled] )
		return NULL;
	    
	@synchronized(self)
	{
        _canRealoadRecognizer = NO;
		if ( ! backgroundReco )
		{
			pText = HWR_RecognizeInkData( _recognizer, [inkData dataPtr], 0, -1, asyncReco, flip, FALSE, selection );
		}
		else
		{
			if ( HWR_Recognize( _recognizer ) )
				pText = HWR_GetResult( _recognizer );
		}
        _canRealoadRecognizer = YES;
	}		
	if ( pText == NULL || *pText == 0 )
		return NULL;
    return [RecognizerManager stringFromUchr:pText];
}

- (NSString *) getResult
{
    const UCHR * pText = HWR_GetResult( _recognizer );
    if ( pText == NULL || *pText == 0 )
        return NULL;
    return [RecognizerManager stringFromUchr:pText];
}

- (BOOL) isDictionaryWord:(NSString *)word
{
    const UCHR * pWord = [RecognizerManager uchrFromString:word];
	if ( HWR_IsWordInDict( _recognizer, pWord ) )
		return YES;
    /*
	if ( [[LanguageManager sharedManager] spellCheckerEnabled] )
	{
		NSRange		currentRange = [[LanguageManager sharedManager] badWordRange:word];
		return (currentRange.location == NSNotFound);
	}
    */
	return NO;
}

- (BOOL) isWordInDictionary:(NSString *)theText
{
	// add here
    if ( [theText length] < 2 )
        return YES;
    const UCHR * chrWord = [RecognizerManager uchrFromString:theText];
	if ( HWR_IsWordInDict( _recognizer, chrWord ) )
		return YES;
//	if ( [[LanguageManager sharedManager] spellCheckerEnabled] )
//	{
//		NSRange		currentRange = [[LanguageManager sharedManager] badWordRange:theText];
//		return (currentRange.location == NSNotFound);
//	}
	return NO;
}

- (void) enableCalculator:(BOOL)bEnable
{
	HWR_EnablePhatCalc( _recognizer, bEnable );
}

- (BOOL) learnNewWord:(NSString *)strWord weight:(UInt16)weight
{
	if ( nil != _recognizer && [strWord length] > 2 )
	{
		const UCHR * pWord = [RecognizerManager uchrFromString:strWord];
        BOOL result = HWR_LearnNewWord( _recognizer, pWord, weight );
        return result;
    }
    return NO;
}

- (BOOL) addWordToUserDict:(NSString *)strWord save:(BOOL)save filter:(BOOL)filter report:(BOOL)report
{
	// add word to the user dictionary
	if ( nil != _recognizer && [strWord length] > 0 )
	{
		const UCHR * pWord = [RecognizerManager uchrFromString:strWord];
		if ( NULL != pWord && (!HWR_IsWordInDict( _recognizer, pWord )) )
		{
			if ( HWR_AddUserWordToDict( _recognizer, pWord, filter ) )
            {
                if ( save )
                {
                    [self saveRecognizerDataOfType:USERDATA_DICTIONARY];
                }
                return YES;
            }
        }
	}
    return NO;
}

- (void) setFlags:(unsigned int)flags
{
    HWR_SetRecognitionFlags( _recognizer, flags );
}

- (unsigned int) getFlags
{
    return HWR_GetRecognitionFlags( _recognizer );
}

- (BOOL) addStroke:(CGStroke)stroke length:(int)len
{
    return HWR_RecognizerAddStroke( _recognizer, stroke, len );
}

- (BOOL) addPoints:(const CGPoint *)points length:(int)len
{
    return HWR_RecognizerAddPoints( _recognizer, points, len );
}

- (BOOL) recognize
{
    return HWR_Recognize( _recognizer );
}

- (BOOL) isWordInArray:(NSString *)word array:(NSArray *)aWords
{
	for ( int i = 0; i < [aWords count]; i++ )
	{
		if ( NSOrderedSame == [word compare:(NSString *)[[aWords objectAtIndex:i] objectForKey:kRecognizerDataWord]] )
			return YES;
	}
	return NO;
}

- (NSArray *) spellCheckWord:(NSString *)word
{
    return [self spellCheckWord:word flags:0 addSpace:NO skipFirst:NO];
}

- (NSArray *) spellCheckWord:(NSString *)word flags:(int)flags addSpace:(BOOL)bAddSpace skipFirst:(BOOL)skipFirst
{
    const UCHR * chrWord = [RecognizerManager uchrFromString:word];
    if ( chrWord == NULL || *chrWord == 0 )
        return nil;
    NSMutableArray * words = nil;
    UCHR  *	pWordList = (UCHR *)malloc( sizeof( UCHR ) *  MAX_STRING_BUFFER );
    if ( nil != pWordList )
    {
        bool singleLetterSpace = (bAddSpace && [[NSUserDefaults standardUserDefaults] boolForKey:kRecoOptionsAddSpaceSingleLetter]) ? true : false;
        if ( HWR_SpellCheckWord( _recognizer, chrWord, pWordList, MAX_STRING_BUFFER-2, flags ) == 0 )
        {
            UCHR *	pResult = malloc( MAX_STRING_BUFFER );
            memset( pResult, 0, MAX_STRING_BUFFER );
            if ( HWR_AnalyzeWordList( _recognizer, pWordList, pResult ) && *pResult != 0 )
            {
                free( (void *)pWordList );
                pWordList = pResult;
            }
            else
            {
                free ( (void *)pResult );
                for ( register int j = 0; 0 != pWordList[j] && j < MAX_STRING_BUFFER; j++ )
                {
                    if ( pWordList[j] == PM_ALTSEP )
                        pWordList[j] = 0;
                }
            }
            words = [NSMutableArray array];
            for ( register int k = 0; k < MAX_STRING_BUFFER; k++ )
            {
                NSMutableString * word = [[RecognizerManager stringFromUchr:&pWordList[k]] mutableCopy];
                if ( ((!skipFirst) || k > 0) && [word length] > 0 )
                {
                    // NOTE: do not add space after single letter
                    if ( bAddSpace )
                    {
                        if ( (singleLetterSpace && [word length] == 1) || [word length] > 1 )
                            [word appendString:@" "];
                    }
                    [words addUniqueCaseString:word];
                }
                while ( 0 != pWordList[k] )
                    k++;
                if ( 0 == pWordList[k+1] )
                    break;
            }
            if ( [words count] < 1 )
            {
                // no words were added, return nil
                words = nil;
            }
        }
        free( pWordList );
    }
    return words;
}

- (NSString *) getResultWord:(int)word_index alternative:(int)alt_inedx isError:(BOOL *)pError
{
    const UCHR *	chrWord = HWR_GetResultWord( _recognizer, word_index, alt_inedx );
    NSString * word = nil;
    *pError = NO;
    if ( NULL != chrWord && 0 != *chrWord )
    {
        unsigned int	recoFlags = HWR_GetRecognitionFlags( _recognizer );
        if ( alt_inedx > 0 && 0 != (recoFlags & FLAG_SUGGESTONLYDICT) )
        {
            if ( ! HWR_IsWordInDict( _recognizer, chrWord ) )
            {
                return nil;
            }
        }
        word = [RecognizerManager stringFromUchr:chrWord];
        if ( nil != word )
        {
            if ( [word rangeOfString:@kEmptyWord].location != NSNotFound )
            {
                *pError = YES;
                return nil;
            }
        }
    }
    return word;
}

- (NSString *) flipCase:(NSString *)word
{
    const UCHR * chrFlipWord = HWR_WordFlipCase( _recognizer, [RecognizerManager uchrFromString:word] );
    if ( chrFlipWord == NULL || *chrFlipWord == 0 )
        return nil;
    return [RecognizerManager stringFromUchr:chrFlipWord];
}

- (NSString *) ensureLower:(NSString *)word
{
    const UCHR * chrLowerWord = HWR_WordEnsureLowerCase( _recognizer, [RecognizerManager uchrFromString:word] );
    if ( chrLowerWord == NULL || *chrLowerWord == 0 )
        return nil;
    return [RecognizerManager stringFromUchr:chrLowerWord];
}

- (NSArray *) generateWordArray:(NSInteger)suggestionCount spellCheck:(BOOL)spellCheck
{
	RECOGNIZER_PTR _reco = _recognizer;
	NSInteger _wordCnt = HWR_GetResultWordCount( _reco );
	if ( _wordCnt < 1 )
		return 0;
    
	NSString *		word = nil;
	USHORT          weight = 0;
	unsigned int	recoFlags = HWR_GetRecognitionFlags( _reco );
    BOOL            bError = NO;
	
	NSMutableArray * words = [NSMutableArray array];
	for ( int iWord = 0; iWord < _wordCnt; iWord++ )
	{
		NSMutableArray * _words = [NSMutableArray array];
		int nAltCnt = HWR_GetResultAlternativeCount( _reco, iWord );
		for ( int j = 0; j < nAltCnt; j++ )
		{
			word = [self getResultWord:iWord alternative:j isError:&bError];
			if ( word != nil )
            {
				// word = [NSString stringWithUTF8String:chrWord];
				weight = HWR_GetResultWeight( _reco, iWord, j );
				// int nstroke = HWR_GetResultStrokesNumber( _reco, iWord, j );
				// NSLog( @"word=%d alt=%d **** strokes=%d ****", iWord, j, nstroke );
				if ( j == 0 || (! [self isWordInArray:word array:_words]) )
				{
                    [_words addObject:@{ kRecognizerDataWord : word,
                                         kRecognizerDataWeight : [NSNumber numberWithUnsignedShort:weight] }];
				}
				if ( j == 0 )
				{
					// add flip-case word to the array, if any
                    NSString * flipped = [self flipCase:word];
					if ( flipped != nil )
					{
						word = flipped;
						if ( ! [self isWordInArray:word array:_words] )
						{
							[_words addObject:@{ kRecognizerDataWord : word,
                                                 kRecognizerDataWeight : [NSNumber numberWithUnsignedShort:weight] }];
						}
					}
                    else
                    {
                        // spell check this word
                        NSArray * spellWords = [self spellCheckWord:word];
                        if ( nil != spellWords && (! [self isWordInArray:word array:_words]) )
                        {
                            [_words addObject:@{ kRecognizerDataWord : [spellWords objectAtIndex:0],
                                                 kRecognizerDataWeight : [NSNumber numberWithUnsignedShort:weight-1] }];
                             
                        }
                    }
				}
			}
            if ( [_words count] >= suggestionCount )
                break;
                
		}
		if ( spellCheck && [_words count] < suggestionCount && 0 != (recoFlags & (FLAG_MAINDICT | FLAG_USERDICT)) )
		{
			// add spell checker results...
			word = [self getResultWord:iWord alternative:0 isError:&bError];
			if ( nil != word )
			{
                NSArray * spellWords = [self spellCheckWord:word];
                if ( nil != spellWords )
                {
                    for ( NSString * word in spellWords )
                    {
                        if ( ! [self isWordInArray:word array:_words] )
                            [_words addObject:@{ kRecognizerDataWord : word,
                                                 kRecognizerDataWeight : [NSNumber numberWithUnsignedShort:0] }];
                        if ( [_words count] >= suggestionCount )
                            break;
                    }
                }
			}
		}
		[words addObject:_words];
	}
	return words;
}

- (NSString *) calcString:(NSString *)strWord
{
    const UCHR * pWord = [RecognizerManager uchrFromString:strWord];
    if ( pWord != NULL )
    {
        pWord = HWR_CalculateString( _recognizer, pWord );
        if ( NULL != pWord )
            return [RecognizerManager stringFromUchr:pWord];
    }
    return strWord;
}

- (NSDictionary *) getAllWords:(unsigned int)recoFlags
{
	// calculate the window size
    NSInteger wordCnt = HWR_GetResultWordCount( _recognizer );
    if ( wordCnt < 1 )
        return nil;

    if ( recoFlags == (unsigned int)(-1) )
    {
        recoFlags = HWR_GetRecognitionFlags( _recognizer );
    }

	register int nAltCnt, iWord, j;
    NSString * result;
	NSMutableArray * words = [NSMutableArray array];
    
    BOOL bAllCaps = ([self getMode] == RECMODE_CAPS) ? YES : NO;
    BOOL bInternet = ([self getMode] == RECMODE_WWW) ? YES : NO;
    BOOL bError = NO;
	for ( iWord = 0; iWord < wordCnt; iWord++ )
	{
		nAltCnt = HWR_GetResultAlternativeCount( _recognizer, iWord );
        int nRowOffset = 0;
		for ( j = 0; j < nAltCnt; j++ )
		{
			result = [self getResultWord:iWord alternative:j isError:&bError];
			if ( result != nil )
			{
                int prob = HWR_GetResultWeight( _recognizer, iWord, j );
                RecognizedWord * word = [[RecognizedWord alloc] init];
                word.word = result;
                
                word.isDict = [self isDictionaryWord:result];
                word.col = iWord;
                word.row = j + nRowOffset;
                word.prob = prob;
                
                [words addObject:word];
				if ( j == 0 )
				{
					// add flip-case word to the array, if any
                    NSString * flipped = (bAllCaps || bInternet) ? nil : [self ensureLower:result];
					if ( nil != flipped )
					{
                        RecognizedWord * word = [[RecognizedWord alloc] init];
                        word.word = flipped;
                        
                        nRowOffset++;
                        word.isDict = YES;
                        word.col = iWord;
                        word.row = j + nRowOffset;
                        word.prob = prob;  //
                        [words addObject:word];
                    }
                    else
                    {
                        // spell check this word if it can't be flipped.
                        NSArray * spellWords = [self spellCheckWord:result];
                        if ( nil != spellWords && [spellWords count] > 0 )
                        {
                            RecognizedWord * word = [[RecognizedWord alloc] init];
                            word.word = [spellWords objectAtIndex:0];
                            if ( bAllCaps )
                                word.word = [word.word uppercaseString];
                            if ( bInternet )
                                word.word = [word.word lowercaseString];
                            
                            nRowOffset++;
                            word.isDict = YES;
                            word.col = iWord;
                            word.row = j + nRowOffset;
                            word.prob = prob-1; // lower the probability
                            
                            
                            [words addObject:word];
                        }
                    }
				}
			}
		}
    }
    
    if ( bError )
    {
        RecognizedWord * word = [[RecognizedWord alloc] init];
        word.word = @"Input Error!";
        word.isDict = NO;
        word.col = 0;
        word.row = 0;
        word.prob = 0;
        
        NSDictionary * _result = @{ kRecognizerDataWords : @[word], @"count" : [NSNumber numberWithInteger:1], @"error" : [NSNumber numberWithBool:YES]};
        return _result;
    }
    
    if ( [words count] < 1 )
    {
        return nil;
    }
    NSDictionary * _result = @{ kRecognizerDataWords : words, @"count" : [NSNumber numberWithInteger:wordCnt], @"error" : [NSNumber numberWithBool:NO] };
    return _result;
}

- (BOOL)replaceWord:(NSString *)wordFrom probability1:(USHORT)prob1 wordTo:(NSString *)wordTo probability2:(USHORT)prob2
{
    const UCHR * word1 = [RecognizerManager uchrFromString:wordFrom];
    const UCHR * word2 = [RecognizerManager uchrFromString:wordTo];
    if ( word1 == NULL || word2 == NULL )
        return NO;
    
    BOOL result = HWR_ReplaceWord( _recognizer, word1, prob1, word2, prob2 );
    return result;
}

- (USHORT) getWeight:(int)word alternative:(int)alt
{
    return HWR_GetResultWeight( _recognizer, word, alt );
}

- (NSString * _Nonnull) autocorrectedWord:(NSString * _Nonnull)word
{
    NSString * wordOut = word;
    if ( [word length] > 0 )
    {
        const UCHR * wout = HWR_AutocorrectWord( _recognizer, [RecognizerManager uchrFromString:word] );
        if ( wout != NULL )
            wordOut = [RecognizerManager stringFromUchr:wout];
    }
    return wordOut;
}

@end
