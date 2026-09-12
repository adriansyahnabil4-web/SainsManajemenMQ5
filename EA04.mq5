//+------------------------------------------------------------------+
//|                                                   EA04.mq5       |
//|              EMA Crossover + ATR Risk Management                |
//|                         Pure MQL5 / MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.01"
#property description "EMA Crossover Expert Advisor with ATR-based SL/TP"
#property description "Pure MQL5 - no deprecated MQL4 functions"

#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== General Settings ==="
input ulong InpMagicNumber       = 10004;
input bool  InpAllowBuy          = true;
input bool  InpAllowSell         = true;
input bool  InpOnePositionOnly   = true;
input bool  InpCloseOnReverse    = true;
input bool  InpNewBarOnly        = true;

input group "=== EMA Settings ==="
input int InpFastMAPeriod = 20;
input int InpSlowMAPeriod = 50;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== ATR Risk Management ==="
input int InpATRPeriod = 14;
input double InpSL_ATR_Multiplier = 2.0;
input double InpTP_ATR_Multiplier = 3.0;

input group "=== Money Management ==="
input bool InpUseRiskPercent = false;
input double InpRiskPercent = 1.0;
input double InpFixedLot = 0.10;

input group "=== Trade Settings ==="
input int InpDeviationPoints = 20;
input bool InpUseSpreadFilter = false;
input double InpMaxSpreadPoints = 50.0;

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

int g_fastMAHandle = INVALID_HANDLE;
int g_slowMAHandle = INVALID_HANDLE;
int g_atrHandle    = INVALID_HANDLE;

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpMagicNumber == 0)
   {
      Print("ERROR: Magic Number must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0)
   {
      Print("ERROR: EMA periods must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastMAPeriod >= InpSlowMAPeriod)
   {
      Print("ERROR: Fast EMA must be smaller than Slow EMA.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpATRPeriod <= 0)
   {
      Print("ERROR: ATR period must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSL_ATR_Multiplier <= 0.0 ||
      InpTP_ATR_Multiplier <= 0.0)
   {
      Print("ERROR: ATR multipliers must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseRiskPercent)
   {
      if(InpRiskPercent <= 0.0)
      {
         Print("ERROR: Risk percent must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   else
   {
      if(InpFixedLot <= 0.0)
      {
         Print("ERROR: Fixed lot must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   if(InpDeviationPoints < 0)
   {
      Print("ERROR: Deviation cannot be negative.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseSpreadFilter && InpMaxSpreadPoints <= 0.0)
   {
      Print("ERROR: Maximum spread must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolSelect(_Symbol, true))
   {
      Print("ERROR: Failed to select symbol ", _Symbol);
      return INIT_FAILED;
   }

   //--- Create Fast EMA
   g_fastMAHandle = iMA(
      _Symbol,
      PERIOD_CURRENT,
      InpFastMAPeriod,
      0,
      MODE_EMA,
      InpMAPrice
   );

   if(g_fastMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Fast EMA. Error: ",
            GetLastError());
      return INIT_FAILED;
   }

   //--- Create Slow EMA
   g_slowMAHandle = iMA(
      _Symbol,
      PERIOD_CURRENT,
      InpSlowMAPeriod,
      0,
      MODE_EMA,
      InpMAPrice
   );

   if(g_slowMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Slow EMA. Error: ",
            GetLastError());

      IndicatorRelease(g_fastMAHandle);
      g_fastMAHandle = INVALID_HANDLE;

      return INIT_FAILED;
   }

   //--- Create ATR
   g_atrHandle = iATR(
      _Symbol,
      PERIOD_CURRENT,
      InpATRPeriod
   );

   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR. Error: ",
            GetLastError());

      IndicatorRelease(g_fastMAHandle);
      IndicatorRelease(g_slowMAHandle);

      g_fastMAHandle = INVALID_HANDLE;
      g_slowMAHandle = INVALID_HANDLE;

      return INIT_FAILED;
   }

   //--- Configure trading object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Initialize current bar
   g_lastBarTime = iTime(
      _Symbol,
      PERIOD_CURRENT,
      0
   );

   Print("========================================");
   Print("EA04 INITIALIZED");
   Print("Symbol       : ", _Symbol);
   Print("Timeframe    : ", EnumToString(PERIOD_CURRENT));
   Print("Magic Number : ", InpMagicNumber);
   Print("Fast EMA     : ", InpFastMAPeriod);
   Print("Slow EMA     : ", InpSlowMAPeriod);
   Print("ATR Period   : ", InpATRPeriod);
   Print("========================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_fastMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_fastMAHandle);
      g_fastMAHandle = INVALID_HANDLE;
   }

   if(g_slowMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_slowMAHandle);
      g_slowMAHandle = INVALID_HANDLE;
   }

   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(InpNewBarOnly)
   {
      if(!IsNewBar())
         return;
   }

   if(InpUseSpreadFilter)
   {
      if(!IsSpreadAcceptable())
         return;
   }

   if(!IndicatorsReady())
      return;

   int signal = GetSignal();

   if(signal == 0)
      return;

   ProcessSignal(signal);
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(
      _Symbol,
      PERIOD_CURRENT,
      0
   );

   if(currentBarTime <= 0)
      return false;

   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Indicator readiness                                              |
//+------------------------------------------------------------------+
bool IndicatorsReady()
{
   if(g_fastMAHandle == INVALID_HANDLE ||
      g_slowMAHandle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE)
   {
      return false;
   }

   int fastBars = BarsCalculated(g_fastMAHandle);
   int slowBars = BarsCalculated(g_slowMAHandle);
   int atrBars  = BarsCalculated(g_atrHandle);

   int minimumBars = MathMax(
      InpSlowMAPeriod,
      InpATRPeriod
   ) + 5;

   if(fastBars < minimumBars ||
      slowBars < minimumBars ||
      atrBars < minimumBars)
   {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Get EMA crossover signal                                         |
//|                                                                  |
//|  1  = BUY                                                        |
//| -1  = SELL                                                       |
//|  0  = NONE                                                       |
//+------------------------------------------------------------------+
int GetSignal()
{
   double fastMA[];
   double slowMA[];

   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);

   if(CopyBuffer(
      g_fastMAHandle,
      0,
      1,
      3,
      fastMA
   ) != 3)
   {
      return 0;
   }

   if(CopyBuffer(
      g_slowMAHandle,
      0,
      1,
      3,
      slowMA
   ) != 3)
   {
      return 0;
   }

   double fastCurrent = fastMA[0];
   double fastPrevious = fastMA[1];

   double slowCurrent = slowMA[0];
   double slowPrevious = slowMA[1];

   //--- Bullish crossover
   if(fastPrevious <= slowPrevious &&
      fastCurrent > slowCurrent)
   {
      return 1;
   }

   //--- Bearish crossover
   if(fastPrevious >= slowPrevious &&
      fastCurrent < slowCurrent)
   {
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Process signal                                                   |
//+------------------------------------------------------------------+
void ProcessSignal(const int signal)
{
   ulong ticket = 0;
   ENUM_POSITION_TYPE positionType;

   bool hasPosition = FindOurPosition(
      _Symbol,
      ticket,
      positionType
   );

   //--- BUY
   if(signal == 1)
   {
      if(!InpAllowBuy)
         return;

      if(hasPosition)
      {
         if(positionType == POSITION_TYPE_BUY)
            return;

         if(positionType == POSITION_TYPE_SELL)
         {
            if(!InpCloseOnReverse)
               return;

            if(!ClosePosition(ticket))
               return;
         }
      }

      if(InpOnePositionOnly && HasOurPosition(_Symbol))
         return;

      OpenBuy();
      return;
   }

   //--- SELL
   if(signal == -1)
   {
      if(!InpAllowSell)
         return;

      if(hasPosition)
      {
         if(positionType == POSITION_TYPE_SELL)
            return;

         if(positionType == POSITION_TYPE_BUY)
         {
            if(!InpCloseOnReverse)
               return;

            if(!ClosePosition(ticket))
               return;
         }
      }

      if(InpOnePositionOnly && HasOurPosition(_Symbol))
         return;

      OpenSell();
   }
}

//+------------------------------------------------------------------+
//| Open BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double atr = GetATR();

   if(atr <= 0.0)
      return false;

   double ask = SymbolInfoDouble(
      _Symbol,
      SYMBOL_ASK
   );

   if(ask <= 0.0)
      return false;

   double sl = ask -
               (atr * InpSL_ATR_Multiplier);

   double tp = ask +
               (atr * InpTP_ATR_Multiplier);

   AdjustStopsForBuy(
      ask,
      sl,
      tp
   );

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   double volume = CalculateVolume(
      ORDER_TYPE_BUY,
      ask,
      sl
   );

   if(volume <= 0.0)
      return false;

   ResetLastError();

   bool result = trade.Buy(
      volume,
      _Symbol,
      0.0,
      sl,
      tp,
      "EA04 EMA Cross BUY"
   );

   if(!result)
   {
      Print(
         "BUY FAILED | Retcode: ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "BUY OPENED | Symbol: ",
      _Symbol,
      " | Volume: ",
      DoubleToString(volume, 8),
      " | SL: ",
      DoubleToString(sl, _Digits),
      " | TP: ",
      DoubleToString(tp, _Digits)
   );

   return true;
}

//+------------------------------------------------------------------+
//| Open SELL                                                        |
//+------------------------------------------------------------------+
bool OpenSell()
{
   double atr = GetATR();

   if(atr <= 0.0)
      return false;

   double bid = SymbolInfoDouble(
      _Symbol,
      SYMBOL_BID
   );

   if(bid <= 0.0)
      return false;

   double sl = bid +
               (atr * InpSL_ATR_Multiplier);

   double tp = bid -
               (atr * InpTP_ATR_Multiplier);

   AdjustStopsForSell(
      bid,
      sl,
      tp
   );

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   double volume = CalculateVolume(
      ORDER_TYPE_SELL,
      bid,
      sl
   );

   if(volume <= 0.0)
      return false;

   ResetLastError();

   bool result = trade.Sell(
      volume,
      _Symbol,
      0.0,
      sl,
      tp,
      "EA04 EMA Cross SELL"
   );

   if(!result)
   {
      Print(
         "SELL FAILED | Retcode: ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "SELL OPENED | Symbol: ",
      _Symbol,
      " | Volume: ",
      DoubleToString(volume, 8),
      " | SL: ",
      DoubleToString(sl, _Digits),
      " | TP: ",
      DoubleToString(tp, _Digits)
   );

   return true;
}

//+------------------------------------------------------------------+
//| Get ATR                                                          |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];

   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(
      g_atrHandle,
      0,
      1,
      1,
      atrBuffer
   ) != 1)
   {
      return 0.0;
   }

   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Find our position                                                |
//+------------------------------------------------------------------+
bool FindOurPosition(
   const string symbol,
   ulong &ticket,
   ENUM_POSITION_TYPE &positionType
)
{
   ticket = 0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong currentTicket =
         PositionGetTicket(i);

      if(currentTicket == 0)
         continue;

      if(!PositionSelectByTicket(currentTicket))
         continue;

      string currentSymbol =
         PositionGetString(POSITION_SYMBOL);

      if(currentSymbol != symbol)
         continue;

      long currentMagic =
         PositionGetInteger(POSITION_MAGIC);

      if((ulong)currentMagic != InpMagicNumber)
         continue;

      positionType =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE);

      ticket = currentTicket;

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check our position                                               |
//+------------------------------------------------------------------+
bool HasOurPosition(const string symbol)
{
   ulong ticket = 0;
   ENUM_POSITION_TYPE type;

   return FindOurPosition(
      symbol,
      ticket,
      type
   );
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
bool ClosePosition(const ulong ticket)
{
   if(ticket == 0)
      return false;

   if(!PositionSelectByTicket(ticket))
      return false;

   long magic =
      PositionGetInteger(POSITION_MAGIC);

   if((ulong)magic != InpMagicNumber)
   {
      Print(
         "SAFETY BLOCK: Magic number mismatch."
      );

      return false;
   }

   string symbol =
      PositionGetString(POSITION_SYMBOL);

   bool result = trade.PositionClose(
      ticket,
      InpDeviationPoints
   );

   if(!result)
   {
      Print(
         "CLOSE FAILED | Ticket: ",
         ticket,
         " | Symbol: ",
         symbol,
         " | Retcode: ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "POSITION CLOSED | Ticket: ",
      ticket,
      " | Symbol: ",
      symbol
   );

   return true;
}

//+------------------------------------------------------------------+
//| Calculate volume                                                 |
//+------------------------------------------------------------------+
double CalculateVolume(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double stopLoss
)
{
   double volume = 0.0;

   if(!InpUseRiskPercent)
   {
      volume = InpFixedLot;
   }
   else
   {
      double equity =
         AccountInfoDouble(ACCOUNT_EQUITY);

      double riskMoney =
         equity *
         InpRiskPercent /
         100.0;

      if(riskMoney <= 0.0)
         return 0.0;

      double tickSize =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_TRADE_TICK_SIZE
         );

      double tickValue = 0.0;

      if(orderType == ORDER_TYPE_BUY)
      {
         tickValue =
            SymbolInfoDouble(
               _Symbol,
               SYMBOL_TRADE_TICK_VALUE_LOSS
            );

         if(tickValue <= 0.0)
         {
            tickValue =
               SymbolInfoDouble(
                  _Symbol,
                  SYMBOL_TRADE_TICK_VALUE
               );
         }
      }
      else
      {
         tickValue =
            SymbolInfoDouble(
               _Symbol,
               SYMBOL_TRADE_TICK_VALUE_LOSS
            );

         if(tickValue <= 0.0)
         {
            tickValue =
               SymbolInfoDouble(
                  _Symbol,
                  SYMBOL_TRADE_TICK_VALUE
               );
         }
      }

      if(tickSize <= 0.0 ||
         tickValue <= 0.0)
      {
         return 0.0;
      }

      double priceDistance =
         MathAbs(
            entryPrice - stopLoss
         );

      if(priceDistance <= 0.0)
         return 0.0;

      double lossPerLot =
         (priceDistance / tickSize) *
         tickValue;

      if(lossPerLot <= 0.0)
         return 0.0;

      volume =
         riskMoney /
         lossPerLot;
   }

   return NormalizeVolume(volume);
}

//+------------------------------------------------------------------+
//| Normalize volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(
   const double requestedVolume
)
{
   double minVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double stepVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(minVolume <= 0.0 ||
      maxVolume <= 0.0 ||
      stepVolume <= 0.0)
   {
      return 0.0;
   }

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

   if(volume < minVolume)
      volume = minVolume;

   int volumeDigits = 0;

   double step = stepVolume;

   while(step < 1.0 &&
         volumeDigits < 8)
   {
      step *= 10.0;
      volumeDigits++;
   }

   return NormalizeDouble(
      volume,
      volumeDigits
   );
}

//+------------------------------------------------------------------+
//| Normalize price                                                  |
//+------------------------------------------------------------------+
double NormalizePrice(
   const double price
)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0.0)
      return NormalizeDouble(
         price,
         _Digits
      );

   double normalized =
      MathRound(
         price / tickSize
      ) * tickSize;

   return NormalizeDouble(
      normalized,
      _Digits
   );
}

//+------------------------------------------------------------------+
//| Adjust BUY stops                                                 |
//+------------------------------------------------------------------+
void AdjustStopsForBuy(
   const double entryPrice,
   double &sl,
   double &tp
)
{
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double minimumDistance =
      (double)stopsLevel * _Point;

   if(minimumDistance <= 0.0)
      return;

   if(entryPrice - sl < minimumDistance)
      sl =
         entryPrice -
         minimumDistance;

   if(tp - entryPrice < minimumDistance)
      tp =
         entryPrice +
         minimumDistance;
}

//+------------------------------------------------------------------+
//| Adjust SELL stops                                                |
//+------------------------------------------------------------------+
void AdjustStopsForSell(
   const double entryPrice,
   double &sl,
   double &tp
)
{
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double minimumDistance =
      (double)stopsLevel * _Point;

   if(minimumDistance <= 0.0)
      return;

   if(sl - entryPrice < minimumDistance)
      sl =
         entryPrice +
         minimumDistance;

   if(entryPrice - tp < minimumDistance)
      tp =
         entryPrice -
         minimumDistance;
}

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );

   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );

   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double spreadPoints =
      (ask - bid) / _Point;

   return (
      spreadPoints <=
      InpMaxSpreadPoints
   );
}

//+------------------------------------------------------------------+
//| Trade transaction                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long magic =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_MAGIC
      );

   if((ulong)magic != InpMagicNumber)
      return;

   string symbol =
      HistoryDealGetString(
         trans.deal,
         DEAL_SYMBOL
      );

   long dealType =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_TYPE
      );

   long entry =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_ENTRY
      );

   double volume =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_VOLUME
      );

   double price =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_PRICE
      );

   Print(
      "EA04 TRANSACTION | Symbol: ",
      symbol,
      " | Deal: ",
      trans.deal,
      " | Type: ",
      EnumToString(
         (ENUM_DEAL_TYPE)dealType
      ),
      " | Entry: ",
      EnumToString(
         (ENUM_DEAL_ENTRY)entry
      ),
      " | Volume: ",
      DoubleToString(volume, 8),
      " | Price: ",
      DoubleToString(price, _Digits)
   );
}
//+------------------------------------------------------------------+