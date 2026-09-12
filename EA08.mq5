//+------------------------------------------------------------------+
//|                                                   EA08.mq5       |
//|                US30 Daily ATR Position Builder                  |
//|                                                                  |
//|                         Pure MQL5 / MT5                         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EA08 - US30 Daily ATR Position Builder"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================

//--- Trading
input string InpSymbol                  = "US30";
input ulong  InpMagicNumber             = 30006;
input double InpLotSize                 = 0.10;
input int    InpDeviationPoints         = 50;

//--- Initial entry time - broker/server time
input int    InpOpenHour                = 16;
input int    InpOpenMinute              = 30;

//--- ATR
input int    InpATRPeriod               = 14;

//--- Position building
input double InpPullbackATR             = 1.0;
input double InpStopLossATR             = 1.2;
input double InpBreakEvenATR            = 1.5;

//--- Equity management
input double InpTargetProfitPercent     = 10.0;
input double InpFailsafeDrawdownPercent = 5.0;


//====================================================================
// GLOBAL STATE
//====================================================================

int      g_atrHandle          = INVALID_HANDLE;
double   g_dailyATR           = 0.0;
datetime g_atrDay             = 0;

double   g_referenceEquity    = 0.0;
double   g_lastEntryPrice     = 0.0;

datetime g_initialTradeDay    = 0;

bool     g_orderInProgress    = false;
bool     g_shutdownTrading    = false;


//====================================================================
// DAY UTILITIES
//====================================================================

datetime GetDayStart(const datetime value)
{
   MqlDateTime dt;

   if(!TimeToStruct(value, dt))
      return 0;

   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   return StructToTime(dt);
}


//====================================================================
// SYMBOL UTILITIES
//====================================================================

int GetSymbolDigits()
{
   return (int)SymbolInfoInteger(
      InpSymbol,
      SYMBOL_DIGITS
   );
}


double GetSymbolPoint()
{
   return SymbolInfoDouble(
      InpSymbol,
      SYMBOL_POINT
   );
}


double NormalizePrice(const double price)
{
   return NormalizeDouble(
      price,
      GetSymbolDigits()
   );
}


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
      MathMax(
         stopsLevel,
         freezeLevel
      );

   return (double)requiredLevel *
          GetSymbolPoint();
}


//====================================================================
// VOLUME
//====================================================================

double NormalizeVolume(const double requestedVolume)
{
   const double minVolume =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_VOLUME_MIN
      );

   const double maxVolume =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_VOLUME_MAX
      );

   const double stepVolume =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_VOLUME_STEP
      );

   if(stepVolume <= 0.0)
      return 0.0;

   double volume = requestedVolume;

   volume = MathMax(
      volume,
      minVolume
   );

   volume = MathMin(
      volume,
      maxVolume
   );

   volume =
      MathFloor(
         volume / stepVolume
      ) * stepVolume;

   int digits = 0;
   double step = stepVolume;

   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return NormalizeDouble(
      volume,
      digits
   );
}


//====================================================================
// ATR
//====================================================================

bool UpdateDailyATR()
{
   if(g_atrHandle == INVALID_HANDLE)
      return false;

   double buffer[1];

   // Previous completed D1 candle
   const int copied =
      CopyBuffer(
         g_atrHandle,
         0,
         1,
         1,
         buffer
      );

   if(copied != 1)
      return false;

   if(buffer[0] <= 0.0)
      return false;

   g_dailyATR = buffer[0];

   g_atrDay =
      GetDayStart(
         TimeCurrent()
      );

   return true;
}


//====================================================================
// POSITION FILTER
//====================================================================

bool IsOurBuyPosition(const ulong ticket)
{
   if(ticket == 0)
      return false;

   if(!PositionSelectByTicket(ticket))
      return false;

   const string symbol =
      PositionGetString(
         POSITION_SYMBOL
      );

   const ulong magic =
      (ulong)PositionGetInteger(
         POSITION_MAGIC
      );

   const ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(
         POSITION_TYPE
      );

   if(symbol != InpSymbol)
      return false;

   if(magic != InpMagicNumber)
      return false;

   if(type != POSITION_TYPE_BUY)
      return false;

   return true;
}


//====================================================================
// COUNT OUR POSITIONS
//====================================================================

int CountOurPositions()
{
   int count = 0;

   const int total =
      PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket =
         PositionGetTicket(i);

      if(IsOurBuyPosition(ticket))
         count++;
   }

   return count;
}


//====================================================================
// FIND LATEST ENTRY
//====================================================================

double FindLatestEntryPrice()
{
   double latestPrice = 0.0;
   long latestTime = -1;

   const int total =
      PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket =
         PositionGetTicket(i);

      if(!IsOurBuyPosition(ticket))
         continue;

      const long positionTime =
         PositionGetInteger(
            POSITION_TIME_MSC
         );

      if(positionTime >= latestTime)
      {
         latestTime = positionTime;

         latestPrice =
            PositionGetDouble(
               POSITION_PRICE_OPEN
            );
      }
   }

   return latestPrice;
}


//====================================================================
// INITIAL ENTRY CHECK
//====================================================================

bool IsInitialEntryTime()
{
   MqlDateTime dt;

   if(!TimeToStruct(
         TimeCurrent(),
         dt))
   {
      return false;
   }

   if(dt.hour != InpOpenHour)
      return false;

   if(dt.min != InpOpenMinute)
      return false;

   return true;
}


bool InitialTradeAlreadyOpened()
{
   return (
      g_initialTradeDay ==
      GetDayStart(
         TimeCurrent()
      )
   );
}


//====================================================================
// EQUITY MANAGEMENT
//====================================================================

bool TargetReached()
{
   if(g_referenceEquity <= 0.0)
      return false;

   if(InpTargetProfitPercent <= 0.0)
      return false;

   const double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   const double target =
      g_referenceEquity *
      (1.0 +
       InpTargetProfitPercent / 100.0);

   return equity >= target;
}


bool FailsafeTriggered()
{
   if(g_referenceEquity <= 0.0)
      return false;

   if(InpFailsafeDrawdownPercent <= 0.0)
      return false;

   const double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   const double limit =
      g_referenceEquity *
      (1.0 -
       InpFailsafeDrawdownPercent / 100.0);

   return equity <= limit;
}


//====================================================================
// CLOSE ALL OUR POSITIONS
//====================================================================

bool CloseAllOurPositions()
{
   bool success = true;

   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
   {
      const ulong ticket =
         PositionGetTicket(i);

      if(!IsOurBuyPosition(ticket))
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print(
            "EA06 | Failed to close #",
            ticket,
            " | Retcode=",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );

         success = false;
      }
   }

   return success;
}


//====================================================================
// STOP LOSS CALCULATION
//====================================================================

double CalculateInitialStop(
   const double entryPrice,
   const double bid
)
{
   double stop =
      entryPrice -
      (
         g_dailyATR *
         InpStopLossATR
      );

   const double minimumDistance =
      GetMinimumStopDistance();

   const double maximumAllowedSL =
      bid -
      minimumDistance;

   if(stop > maximumAllowedSL)
      stop = maximumAllowedSL;

   return NormalizePrice(stop);
}


//====================================================================
// OPEN BUY
//====================================================================

bool OpenBuy()
{
   if(g_orderInProgress)
      return false;

   if(g_shutdownTrading)
      return false;

   if(g_dailyATR <= 0.0)
      return false;

   g_orderInProgress = true;

   const double ask =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_ASK
      );

   const double bid =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_BID
      );

   if(ask <= 0.0 ||
      bid <= 0.0)
   {
      g_orderInProgress = false;
      return false;
   }

   const double volume =
      NormalizeVolume(
         InpLotSize
      );

   if(volume <= 0.0)
   {
      g_orderInProgress = false;
      return false;
   }

   const double stopLoss =
      CalculateInitialStop(
         ask,
         bid
      );

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      InpSymbol
   );

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
         "EA06 | BUY failed | Retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      g_orderInProgress = false;

      return false;
   }

   double executionPrice =
      trade.ResultPrice();

   if(executionPrice <= 0.0)
      executionPrice = ask;

   g_lastEntryPrice =
      executionPrice;

   Print(
      "EA06 | BUY opened | Entry=",
      DoubleToString(
         executionPrice,
         GetSymbolDigits()
      ),
      " | ATR=",
      DoubleToString(
         g_dailyATR,
         GetSymbolDigits()
      ),
      " | SL=",
      DoubleToString(
         stopLoss,
         GetSymbolDigits()
      )
   );

   g_orderInProgress = false;

   return true;
}


//====================================================================
// MOVE TO BREAK EVEN
//====================================================================

bool MoveToBreakEven(
   const ulong ticket
)
{
   if(!IsOurBuyPosition(ticket))
      return false;

   const double entryPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   const double currentSL =
      PositionGetDouble(
         POSITION_SL
      );

   const double currentTP =
      PositionGetDouble(
         POSITION_TP
      );

   const double breakEven =
      NormalizePrice(
         entryPrice
      );

   // Already moved to BE
   if(currentSL > 0.0 &&
      currentSL >= breakEven)
   {
      return true;
   }

   if(!trade.PositionModify(
         ticket,
         breakEven,
         currentTP))
   {
      Print(
         "EA06 | BE failed #",
         ticket,
         " | Retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "EA06 | Position #",
      ticket,
      " moved to BE"
   );

   return true;
}


//====================================================================
// BREAK-EVEN MANAGEMENT
//====================================================================

void ManageBreakEven()
{
   if(g_dailyATR <= 0.0)
      return;

   const double bid =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_BID
      );

   if(bid <= 0.0)
      return;

   const int total =
      PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      const ulong ticket =
         PositionGetTicket(i);

      if(!IsOurBuyPosition(ticket))
         continue;

      const double entry =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      const double sl =
         PositionGetDouble(
            POSITION_SL
         );

      // Already protected
      if(sl > 0.0 &&
         sl >= entry)
      {
         continue;
      }

      const double trigger =
         entry +
         (
            g_dailyATR *
            InpBreakEvenATR
         );

      if(bid >= trigger)
      {
         MoveToBreakEven(ticket);
      }
   }
}


//====================================================================
// INITIAL ENTRY
//====================================================================

void CheckInitialEntry()
{
   if(!IsInitialEntryTime())
      return;

   if(InitialTradeAlreadyOpened())
      return;

   if(CountOurPositions() > 0)
      return;

   if(OpenBuy())
   {
      g_initialTradeDay =
         GetDayStart(
            TimeCurrent()
         );
   }
}


//====================================================================
// PULLBACK ENTRY
//====================================================================

void CheckPullbackEntry()
{
   if(g_orderInProgress)
      return;

   if(g_dailyATR <= 0.0)
      return;

   if(CountOurPositions() <= 0)
      return;

   const double bid =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_BID
      );

   if(bid <= 0.0)
      return;

   if(g_lastEntryPrice <= 0.0)
   {
      g_lastEntryPrice =
         FindLatestEntryPrice();
   }

   if(g_lastEntryPrice <= 0.0)
      return;

   const double pullbackLevel =
      g_lastEntryPrice -
      (
         g_dailyATR *
         InpPullbackATR
      );

   if(bid <= pullbackLevel)
   {
      OpenBuy();
   }
}


//====================================================================
// INITIALIZATION
//====================================================================

int OnInit()
{
   //--- Validate symbol
   if(!SymbolSelect(
         InpSymbol,
         true))
   {
      Print(
         "EA06 | Cannot select symbol: ",
         InpSymbol
      );

      return INIT_FAILED;
   }

   //--- Validate inputs
   if(InpLotSize <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpATRPeriod <= 0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpPullbackATR <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpStopLossATR <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpBreakEvenATR <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpTargetProfitPercent < 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpFailsafeDrawdownPercent < 0.0)
      return INIT_PARAMETERS_INCORRECT;

   //--- Create ATR handle once
   g_atrHandle =
      iATR(
         InpSymbol,
         PERIOD_D1,
         InpATRPeriod
      );

   if(g_atrHandle == INVALID_HANDLE)
   {
      Print(
         "EA06 | ATR handle creation failed. Error=",
         GetLastError()
      );

      return INIT_FAILED;
   }

   //--- Store starting equity
   g_referenceEquity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   if(g_referenceEquity <= 0.0)
   {
      IndicatorRelease(
         g_atrHandle
      );

      g_atrHandle =
         INVALID_HANDLE;

      return INIT_FAILED;
   }

   //--- Configure trade object
   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      InpSymbol
   );

   //--- Load ATR
   UpdateDailyATR();

   //--- Recover state from open positions
   g_lastEntryPrice =
      FindLatestEntryPrice();

   Print(
      "===================================="
   );

   Print(
      "EA06 INITIALIZED"
   );

   Print(
      "Symbol: ",
      InpSymbol
   );

   Print(
      "Magic: ",
      InpMagicNumber
   );

   Print(
      "Reference Equity: ",
      DoubleToString(
         g_referenceEquity,
         2
      )
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
      "===================================="
   );

   return INIT_SUCCEEDED;
}


//====================================================================
// DEINITIALIZATION
//====================================================================

void OnDeinit(
   const int reason
)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(
         g_atrHandle
      );

      g_atrHandle =
         INVALID_HANDLE;
   }
}


//====================================================================
// MAIN TICK
//====================================================================

void OnTick()
{
   //--- Update ATR only when day changes
   const datetime now =
      TimeCurrent();

   const datetime today =
      GetDayStart(now);

   if(today != g_atrDay)
   {
      UpdateDailyATR();
   }

   if(g_dailyATR <= 0.0)
      return;


   //===============================================================
   // FAILSAFE HAS HIGHEST PRIORITY
   //===============================================================

   if(FailsafeTriggered())
   {
      Print(
         "EA06 | FAILSAFE TRIGGERED | Equity=",
         DoubleToString(
            AccountInfoDouble(
               ACCOUNT_EQUITY
            ),
            2
         )
      );

      g_shutdownTrading = true;

      CloseAllOurPositions();

      return;
   }


   //===============================================================
   // PROFIT TARGET
   //===============================================================

   if(TargetReached())
   {
      Print(
         "EA06 | TARGET REACHED | Equity=",
         DoubleToString(
            AccountInfoDouble(
               ACCOUNT_EQUITY
            ),
            2
         )
      );

      g_shutdownTrading = true;

      CloseAllOurPositions();

      return;
   }


   //===============================================================
   // MANAGE EXISTING POSITIONS
   //===============================================================

   ManageBreakEven();


   //===============================================================
   // INITIAL MARKET OPEN ENTRY
   //===============================================================

   if(!g_shutdownTrading)
   {
      CheckInitialEntry();
   }


   //===============================================================
   // ADDITIONAL PULLBACK ENTRY
   //===============================================================

   if(!g_shutdownTrading)
   {
      CheckPullbackEntry();
   }
}
//+------------------------------------------------------------------+