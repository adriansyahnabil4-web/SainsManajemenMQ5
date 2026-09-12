//+------------------------------------------------------------------+
//|                                                   EA06.mq5       |
//|                  US30 Daily ATR Position Builder                 |
//|                                                                  |
//|                         Pure Modern MQL5                         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EA06 - US30 Daily ATR Position Builder"

//--- Trading library
#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

//--- Trading symbol
input string InpSymbol                  = "US30";

//--- Magic number
input ulong  InpMagicNumber             = 30006;

//--- Fixed lot size
input double InpLotSize                 = 0.10;

//--- Maximum price deviation
input int    InpDeviationPoints         = 50;

//--- Initial market-open entry time
input int    InpOpenHour                = 16;
input int    InpOpenMinute              = 30;

//--- Daily ATR
input int    InpATRPeriod               = 14;

//--- Additional entry after pullback
input double InpPullbackATR             = 1.0;

//--- Initial stop loss
input double InpStopLossATR             = 1.2;

//--- Break-even trigger
input double InpBreakEvenATR            = 1.5;

//--- Equity profit target
input double InpTargetProfitPercent     = 10.0;

//--- Equity drawdown failsafe
input double InpFailsafeDrawdownPercent = 5.0;


//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

//--- ATR indicator handle
int      g_atrHandle = INVALID_HANDLE;

//--- Cached Daily ATR
double   g_dailyATR = 0.0;

//--- Day for which ATR is cached
datetime g_atrDay = 0;

//--- Equity when EA was initialized
double   g_referenceEquity = 0.0;

//--- Most recent EA entry price
double   g_lastEntryPrice = 0.0;

//--- Day on which initial entry was made
datetime g_lastInitialTradeDay = 0;

//--- Prevent simultaneous order requests
bool     g_orderInProgress = false;


//+------------------------------------------------------------------+
//| GET START OF DAY                                                 |
//+------------------------------------------------------------------+
datetime GetDayStart(const datetime timeValue)
{
   MqlDateTime dt;

   if(!TimeToStruct(timeValue, dt))
      return 0;

   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   return StructToTime(dt);
}


//+------------------------------------------------------------------+
//| UPDATE DAILY ATR                                                 |
//+------------------------------------------------------------------+
bool UpdateDailyATR()
{
   if(g_atrHandle == INVALID_HANDLE)
      return false;

   //--- Previous completed D1 candle
   double atrBuffer[1];

   const int copied = CopyBuffer(
      g_atrHandle,
      0,
      1,
      1,
      atrBuffer
   );

   if(copied != 1)
      return false;

   if(atrBuffer[0] <= 0.0)
      return false;

   g_dailyATR = atrBuffer[0];

   g_atrDay = GetDayStart(TimeCurrent());

   return true;
}


//+------------------------------------------------------------------+
//| NORMALIZE VOLUME                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(const double requestedVolume)
{
   const double minVolume =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);

   const double maxVolume =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);

   const double stepVolume =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   if(stepVolume <= 0.0)
      return 0.0;

   double volume = requestedVolume;

   volume = MathMax(volume, minVolume);
   volume = MathMin(volume, maxVolume);

   volume = MathFloor(volume / stepVolume) * stepVolume;

   int digits = 0;
   double step = stepVolume;

   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return NormalizeDouble(volume, digits);
}


//+------------------------------------------------------------------+
//| GET SYMBOL DIGITS                                                |
//+------------------------------------------------------------------+
int GetSymbolDigits()
{
   return (int)SymbolInfoInteger(
      InpSymbol,
      SYMBOL_DIGITS
   );
}


//+------------------------------------------------------------------+
//| GET MINIMUM STOP DISTANCE                                        |
//+------------------------------------------------------------------+
double GetMinimumStopDistance()
{
   const long stopsLevel =
      SymbolInfoInteger(
         InpSymbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   const long freezeLevel =
      SymbolInfoInteger(
         InpSymbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   const long requiredLevel =
      MathMax(stopsLevel, freezeLevel);

   const double point =
      SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   return (double)requiredLevel * point;
}


//+------------------------------------------------------------------+
//| COUNT EA POSITIONS                                               |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;

   const int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol =
         PositionGetString(POSITION_SYMBOL);

      const ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      if(symbol != InpSymbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      if(type != POSITION_TYPE_BUY)
         continue;

      count++;
   }

   return count;
}


//+------------------------------------------------------------------+
//| FIND MOST RECENT ENTRY                                           |
//+------------------------------------------------------------------+
double FindLatestEntryPrice()
{
   double latestPrice = 0.0;
   long latestTime = -1;

   const int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol =
         PositionGetString(POSITION_SYMBOL);

      const ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      if(symbol != InpSymbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      if(type != POSITION_TYPE_BUY)
         continue;

      const long positionTime =
         PositionGetInteger(POSITION_TIME_MSC);

      if(positionTime >= latestTime)
      {
         latestTime = positionTime;

         latestPrice =
            PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return latestPrice;
}


//+------------------------------------------------------------------+
//| CHECK IF INITIAL TRADE WAS MADE TODAY                            |
//+------------------------------------------------------------------+
bool InitialTradeOpenedToday()
{
   const datetime today =
      GetDayStart(TimeCurrent());

   return (g_lastInitialTradeDay == today);
}


//+------------------------------------------------------------------+
//| CHECK MARKET OPEN TIME                                           |
//+------------------------------------------------------------------+
bool IsMarketOpenTime()
{
   MqlDateTime dt;

   if(!TimeToStruct(TimeCurrent(), dt))
      return false;

   if(dt.hour != InpOpenHour)
      return false;

   if(dt.min != InpOpenMinute)
      return false;

   return true;
}


//+------------------------------------------------------------------+
//| TARGET EQUITY CHECK                                              |
//+------------------------------------------------------------------+
bool TargetReached()
{
   if(g_referenceEquity <= 0.0)
      return false;

   if(InpTargetProfitPercent <= 0.0)
      return false;

   const double currentEquity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   const double targetEquity =
      g_referenceEquity *
      (1.0 + InpTargetProfitPercent / 100.0);

   return (currentEquity >= targetEquity);
}


//+------------------------------------------------------------------+
//| FAILSAFE CHECK                                                   |
//+------------------------------------------------------------------+
bool FailsafeTriggered()
{
   if(g_referenceEquity <= 0.0)
      return false;

   if(InpFailsafeDrawdownPercent <= 0.0)
      return false;

   const double currentEquity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   const double failsafeEquity =
      g_referenceEquity *
      (1.0 - InpFailsafeDrawdownPercent / 100.0);

   return (currentEquity <= failsafeEquity);
}


//+------------------------------------------------------------------+
//| CLOSE ALL EA POSITIONS                                           |
//+------------------------------------------------------------------+
bool CloseAllOurPositions()
{
   bool allClosed = true;

   //--- Backwards iteration because positions can disappear
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol =
         PositionGetString(POSITION_SYMBOL);

      const ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != InpSymbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print(
            "EA06 | Failed to close position #",
            ticket,
            " | Retcode: ",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );

         allClosed = false;
      }
   }

   return allClosed;
}


//+------------------------------------------------------------------+
//| ADJUST BUY STOP LOSS                                             |
//+------------------------------------------------------------------+
double AdjustBuyStopLoss(
   const double requestedSL,
   const double currentBid
)
{
   const double minimumDistance =
      GetMinimumStopDistance();

   double stopLoss = requestedSL;

   const double maximumAllowedSL =
      currentBid - minimumDistance;

   if(stopLoss > maximumAllowedSL)
      stopLoss = maximumAllowedSL;

   const int digits = GetSymbolDigits();

   return NormalizeDouble(stopLoss, digits);
}


//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   if(g_dailyATR <= 0.0)
      return false;

   if(g_orderInProgress)
      return false;

   //--- Prevent simultaneous order requests
   g_orderInProgress = true;

   const double ask =
      SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   const double bid =
      SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(ask <= 0.0 || bid <= 0.0)
   {
      g_orderInProgress = false;
      return false;
   }

   const double volume =
      NormalizeVolume(InpLotSize);

   if(volume <= 0.0)
   {
      g_orderInProgress = false;
      return false;
   }

   //--- Initial SL:
   //--- Entry - 1.2 x Daily ATR
   double stopLoss =
      ask -
      (g_dailyATR * InpStopLossATR);

   stopLoss =
      AdjustBuyStopLoss(
         stopLoss,
         bid
      );

   //--- Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(InpSymbol);

   //--- Market BUY
   const bool result =
      trade.Buy(
         volume,
         InpSymbol,
         0.0,
         stopLoss,
         0.0,
         "EA06 ATR BUY"
      );

   if(!result)
   {
      Print(
         "EA06 | BUY failed | Retcode: ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      g_orderInProgress = false;

      return false;
   }

   //--- Use actual execution price if available
   double executedPrice =
      trade.ResultPrice();

   if(executedPrice <= 0.0)
      executedPrice = ask;

   g_lastEntryPrice = executedPrice;

   Print(
      "EA06 | BUY opened | Entry: ",
      DoubleToString(
         executedPrice,
         GetSymbolDigits()
      ),
      " | ATR: ",
      DoubleToString(
         g_dailyATR,
         GetSymbolDigits()
      ),
      " | SL: ",
      DoubleToString(
         stopLoss,
         GetSymbolDigits()
      )
   );

   g_orderInProgress = false;

   return true;
}


//+------------------------------------------------------------------+
//| MOVE POSITION TO BREAK-EVEN                                      |
//+------------------------------------------------------------------+
bool MovePositionToBreakEven(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   const string symbol =
      PositionGetString(POSITION_SYMBOL);

   const ulong magic =
      (ulong)PositionGetInteger(POSITION_MAGIC);

   const ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(
         POSITION_TYPE
      );

   if(symbol != InpSymbol)
      return false;

   if(magic != InpMagicNumber)
      return false;

   if(type != POSITION_TYPE_BUY)
      return false;

   const double entryPrice =
      PositionGetDouble(POSITION_PRICE_OPEN);

   const double currentSL =
      PositionGetDouble(POSITION_SL);

   const double currentTP =
      PositionGetDouble(POSITION_TP);

   const int digits = GetSymbolDigits();

   const double breakEvenPrice =
      NormalizeDouble(
         entryPrice,
         digits
      );

   //--- Already at break-even or better.
   //--- This prevents repeated modifications.
   if(currentSL > 0.0 &&
      currentSL >= breakEvenPrice)
   {
      return true;
   }

   //--- Never move SL backwards
   if(currentSL > 0.0 &&
      currentSL > breakEvenPrice)
   {
      return true;
   }

   //--- Modify position
   if(!trade.PositionModify(
         ticket,
         breakEvenPrice,
         currentTP))
   {
      Print(
         "EA06 | BE failed for #",
         ticket,
         " | Retcode: ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "EA06 | Position #",
      ticket,
      " moved to BE at ",
      DoubleToString(
         breakEvenPrice,
         digits
      )
   );

   return true;
}


//+------------------------------------------------------------------+
//| MANAGE BREAK-EVEN                                                |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(g_dailyATR <= 0.0)
      return;

   const double bid =
      SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(bid <= 0.0)
      return;

   const int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol =
         PositionGetString(POSITION_SYMBOL);

      const ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      if(symbol != InpSymbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      if(type != POSITION_TYPE_BUY)
         continue;

      const double entryPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      const double currentSL =
         PositionGetDouble(POSITION_SL);

      //--- Already moved to BE
      if(currentSL > 0.0 &&
         currentSL >= entryPrice)
      {
         continue;
      }

      //--- BE trigger
      const double breakEvenTrigger =
         entryPrice +
         (g_dailyATR * InpBreakEvenATR);

      if(bid >= breakEvenTrigger)
      {
         MovePositionToBreakEven(ticket);
      }
   }
}


//+------------------------------------------------------------------+
//| CHECK ADDITIONAL PULLBACK ENTRY                                  |
//+------------------------------------------------------------------+
void CheckPullbackEntry()
{
   if(g_dailyATR <= 0.0)
      return;

   if(g_orderInProgress)
      return;

   //--- Need at least one existing position
   if(CountOurPositions() <= 0)
      return;

   const double bid =
      SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(bid <= 0.0)
      return;

   //--- Recover latest entry if necessary
   if(g_lastEntryPrice <= 0.0)
   {
      g_lastEntryPrice =
         FindLatestEntryPrice();
   }

   if(g_lastEntryPrice <= 0.0)
      return;

   //--- Pullback level
   const double pullbackLevel =
      g_lastEntryPrice -
      (g_dailyATR * InpPullbackATR);

   //--- Additional BUY
   if(bid <= pullbackLevel)
   {
      OpenBuy();
   }
}


//+------------------------------------------------------------------+
//| CHECK INITIAL MARKET OPEN ENTRY                                  |
//+------------------------------------------------------------------+
void CheckInitialEntry()
{
   if(!IsMarketOpenTime())
      return;

   //--- Only one initial entry per day
   if(InitialTradeOpenedToday())
      return;

   //--- Do not create initial trade if positions already exist
   if(CountOurPositions() > 0)
      return;

   if(OpenBuy())
   {
      g_lastInitialTradeDay =
         GetDayStart(TimeCurrent());
   }
}


//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   if(!SymbolSelect(InpSymbol, true))
   {
      Print(
         "EA06 | Failed to select symbol: ",
         InpSymbol
      );

      return INIT_FAILED;
   }

   //--- Validate lot size
   if(InpLotSize <= 0.0)
   {
      Print("EA06 | Invalid lot size.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate ATR period
   if(InpATRPeriod <= 0)
   {
      Print("EA06 | Invalid ATR period.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate pullback
   if(InpPullbackATR <= 0.0)
   {
      Print("EA06 | Invalid Pullback ATR.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate SL
   if(InpStopLossATR <= 0.0)
   {
      Print("EA06 | Invalid Stop Loss ATR.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate BE
   if(InpBreakEvenATR <= 0.0)
   {
      Print("EA06 | Invalid Break-Even ATR.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate target
   if(InpTargetProfitPercent < 0.0)
   {
      Print("EA06 | Invalid target percentage.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Validate failsafe
   if(InpFailsafeDrawdownPercent < 0.0)
   {
      Print("EA06 | Invalid failsafe percentage.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Create Daily ATR handle ONCE
   g_atrHandle =
      iATR(
         InpSymbol,
         PERIOD_D1,
         InpATRPeriod
      );

   if(g_atrHandle == INVALID_HANDLE)
   {
      Print(
         "EA06 | Failed to create ATR handle. Error: ",
         GetLastError()
      );

      return INIT_FAILED;
   }

   //--- Store starting equity
   g_referenceEquity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_referenceEquity <= 0.0)
   {
      Print("EA06 | Invalid reference equity.");

      return INIT_FAILED;
   }

   //--- Configure CTrade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(InpSymbol);

   //--- Load ATR immediately
   if(!UpdateDailyATR())
   {
      Print(
         "EA06 | ATR data not ready. ",
         "Waiting for indicator data."
      );
   }

   //--- Recover existing latest position
   g_lastEntryPrice =
      FindLatestEntryPrice();

   //--- Initialization information
   Print("==========================================");
   Print("EA06 INITIALIZED");
   Print("Symbol: ", InpSymbol);
   Print("Magic Number: ", InpMagicNumber);

   Print(
      "Lot Size: ",
      DoubleToString(InpLotSize, 2)
   );

   Print(
      "Reference Equity: ",
      DoubleToString(g_referenceEquity, 2)
   );

   Print(
      "Target: +",
      DoubleToString(
         InpTargetProfitPercent,
         2
      ),
      "%"
   );

   Print(
      "Failsafe: -",
      DoubleToString(
         InpFailsafeDrawdownPercent,
         2
      ),
      "%"
   );

   Print(
      "Initial Entry: ",
      IntegerToString(InpOpenHour),
      ":",
      StringFormat("%02d", InpOpenMinute)
   );

   Print(
      "ATR Period: ",
      InpATRPeriod
   );

   Print(
      "Pullback: ",
      DoubleToString(InpPullbackATR, 2),
      " ATR"
   );

   Print(
      "Stop Loss: ",
      DoubleToString(InpStopLossATR, 2),
      " ATR"
   );

   Print(
      "Break Even: ",
      DoubleToString(InpBreakEvenATR, 2),
      " ATR"
   );

   Print("==========================================");

   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release ATR handle
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);

      g_atrHandle = INVALID_HANDLE;
   }

   Print(
      "EA06 | Deinitialized. Reason: ",
      reason
   );
}


//+------------------------------------------------------------------+
//| EXPERT TICK                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //==============================================================
   // 1. Update cached Daily ATR when a new day begins
   //==============================================================

   const datetime now =
      TimeCurrent();

   const datetime currentDay =
      GetDayStart(now);

   if(currentDay != g_atrDay)
   {
      UpdateDailyATR();
   }

   if(g_dailyATR <= 0.0)
      return;


   //==============================================================
   // 2. PROP-FIRM FAILSAFE
   //==============================================================

   if(FailsafeTriggered())
   {
      Print(
         "EA06 | FAILSAFE TRIGGERED | Equity: ",
         DoubleToString(
            AccountInfoDouble(ACCOUNT_EQUITY),
            2
         )
      );

      CloseAllOurPositions();

      return;
   }


   //==============================================================
   // 3. EQUITY PROFIT TARGET
   //==============================================================

   if(TargetReached())
   {
      Print(
         "EA06 | TARGET REACHED | Equity: ",
         DoubleToString(
            AccountInfoDouble(ACCOUNT_EQUITY),
            2
         )
      );

      CloseAllOurPositions();

      return;
   }


   //==============================================================
   // 4. MANAGE BREAK-EVEN
   //==============================================================

   ManageBreakEven();


   //==============================================================
   // 5. INITIAL 16:30 ENTRY
   //==============================================================

   CheckInitialEntry();


   //==============================================================
   // 6. ADDITIONAL ATR PULLBACK ENTRY
   //==============================================================

   CheckPullbackEntry();
}
//+------------------------------------------------------------------+