//+------------------------------------------------------------------+
//|                                                   EA10.mq5       |
//|              Multi-Strategy / Multi-Currency Expert Advisor     |
//|                         Pure MQL5 / MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "Multi-strategy, multi-instance, multi-currency EA"
#property description "Pure MQL5 - no deprecated MQL4 functions"

//--- MQL5 trade library
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| STRATEGY ENUM                                                    |
//+------------------------------------------------------------------+
enum ENUM_STRATEGY
{
   STRATEGY_01 = 1,
   STRATEGY_02 = 2,
   STRATEGY_03 = 3
};

//+------------------------------------------------------------------+
//| CONSTANTS                                                        |
//+------------------------------------------------------------------+
#define MAX_INSTANCES 20

//+------------------------------------------------------------------+
//| STRATEGY INSTANCE                                                |
//+------------------------------------------------------------------+
struct StrategyInstance
{
   bool            enabled;
   ENUM_STRATEGY   strategy;

   string          symbol;
   ulong           magic;

   double          lot;

   //--- EMA parameters
   int             period_fast;
   int             period_slow;

   //--- RSI parameters
   int             rsi_period;
   double          rsi_buy;
   double          rsi_sell;

   //--- Breakout parameters
   int             breakout_period;

   //--- ATR parameters
   int             atr_period;
   double          atr_sl_multiplier;
   double          atr_tp_multiplier;

   //--- Trading filters
   int             max_spread_points;

   //--- Runtime
   datetime        last_bar_time;

   //--- Indicator handles
   int             handle_fast;
   int             handle_slow;
   int             handle_rsi;
   int             handle_atr;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade Trade;

StrategyInstance Instances[MAX_INSTANCES];

int InstanceCount = 0;


//+------------------------------------------------------------------+
//| GENERAL INPUTS                                                   |
//+------------------------------------------------------------------+
input group "===== GENERAL SETTINGS ====="

input bool   InpEnableTrading       = true;
input bool   InpUseRiskManagement   = false;
input double InpRiskPercent         = 1.0;

input bool   InpOnePositionPerMagic = true;
input bool   InpProcessNewBarOnly   = true;

//--- Timer interval for multicurrency processing
input int    InpTimerSeconds        = 1;


//+------------------------------------------------------------------+
//| STRATEGY 01 - INSTANCE 01                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 01 INSTANCE 01 ====="

input bool   S01_01_Enable       = true;
input string S01_01_Symbol       = "EURUSD";
input ulong  S01_01_Magic        = 10001;
input double S01_01_Lot          = 0.10;

input int    S01_01_FastEMA      = 20;
input int    S01_01_SlowEMA      = 50;

input int    S01_01_ATRPeriod    = 14;
input double S01_01_ATR_SL       = 1.5;
input double S01_01_ATR_TP       = 3.0;

input int    S01_01_MaxSpread    = 30;


//+------------------------------------------------------------------+
//| STRATEGY 02 - INSTANCE 01                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 02 INSTANCE 01 ====="

input bool   S02_01_Enable       = true;
input string S02_01_Symbol       = "GBPUSD";
input ulong  S02_01_Magic        = 20001;
input double S02_01_Lot          = 0.10;

input int    S02_01_RSI_Period   = 14;
input double S02_01_RSI_Buy      = 30.0;
input double S02_01_RSI_Sell     = 70.0;

input int    S02_01_ATRPeriod    = 14;
input double S02_01_ATR_SL       = 1.5;
input double S02_01_ATR_TP       = 3.0;

input int    S02_01_MaxSpread    = 30;


//+------------------------------------------------------------------+
//| STRATEGY 03 - INSTANCE 01                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 03 INSTANCE 01 ====="

input bool   S03_01_Enable          = true;
input string S03_01_Symbol          = "XAUUSD";
input ulong  S03_01_Magic           = 30001;
input double S03_01_Lot             = 0.10;

input int    S03_01_BreakoutPeriod  = 20;

input int    S03_01_ATRPeriod       = 14;
input double S03_01_ATR_SL          = 1.5;
input double S03_01_ATR_TP          = 3.0;

input int    S03_01_MaxSpread       = 100;


//+------------------------------------------------------------------+
//| STRATEGY 01 - INSTANCE 02                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 01 INSTANCE 02 ====="

input bool   S01_02_Enable       = false;
input string S01_02_Symbol       = "GBPUSD";
input ulong  S01_02_Magic        = 10002;
input double S01_02_Lot          = 0.10;

input int    S01_02_FastEMA      = 20;
input int    S01_02_SlowEMA      = 50;

input int    S01_02_ATRPeriod    = 14;
input double S01_02_ATR_SL       = 1.5;
input double S01_02_ATR_TP       = 3.0;

input int    S01_02_MaxSpread    = 30;


//+------------------------------------------------------------------+
//| STRATEGY 02 - INSTANCE 02                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 02 INSTANCE 02 ====="

input bool   S02_02_Enable       = false;
input string S02_02_Symbol       = "USDJPY";
input ulong  S02_02_Magic        = 20002;
input double S02_02_Lot          = 0.10;

input int    S02_02_RSI_Period   = 14;
input double S02_02_RSI_Buy      = 30.0;
input double S02_02_RSI_Sell     = 70.0;

input int    S02_02_ATRPeriod    = 14;
input double S02_02_ATR_SL       = 1.5;
input double S02_02_ATR_TP       = 3.0;

input int    S02_02_MaxSpread    = 30;


//+------------------------------------------------------------------+
//| STRATEGY 03 - INSTANCE 02                                       |
//+------------------------------------------------------------------+
input group "===== STRATEGY 03 INSTANCE 02 ====="

input bool   S03_02_Enable          = false;
input string S03_02_Symbol          = "EURUSD";
input ulong  S03_02_Magic           = 30002;
input double S03_02_Lot             = 0.10;

input int    S03_02_BreakoutPeriod  = 20;

input int    S03_02_ATRPeriod       = 14;
input double S03_02_ATR_SL          = 1.5;
input double S03_02_ATR_TP          = 3.0;

input int    S03_02_MaxSpread       = 30;


//+------------------------------------------------------------------+
//| NORMALIZE LOT                                                    |
//+------------------------------------------------------------------+
double NormalizeLot(
   const string symbol,
   const double requested_lot
)
{
   double min_lot =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MIN
      );

   double max_lot =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_STEP
      );

   if(min_lot <= 0.0 ||
      max_lot <= 0.0)
   {
      return 0.0;
   }

   if(step <= 0.0)
      step = min_lot;

   double lot = requested_lot;

   lot = MathMax(
      min_lot,
      lot
   );

   lot = MathMin(
      max_lot,
      lot
   );

   lot =
      MathFloor(
         lot / step
      ) * step;

   int digits = 0;

   if(step < 1.0)
   {
      digits =
         (int)MathCeil(
            -MathLog10(step)
         );
   }

   return NormalizeDouble(
      lot,
      digits
   );
}


//+------------------------------------------------------------------+
//| CALCULATE RISK LOT                                               |
//+------------------------------------------------------------------+
double CalculateRiskLot(
   const string symbol,
   const double stop_distance,
   const double risk_percent
)
{
   if(stop_distance <= 0.0 ||
      risk_percent <= 0.0)
   {
      return 0.0;
   }

   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );

   double risk_money =
      balance *
      risk_percent /
      100.0;

   double tick_size =
      SymbolInfoDouble(
         symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   double tick_value =
      SymbolInfoDouble(
         symbol,
         SYMBOL_TRADE_TICK_VALUE
      );

   if(tick_size <= 0.0 ||
      tick_value <= 0.0)
   {
      return 0.0;
   }

   double money_per_lot =
      (stop_distance / tick_size) *
      tick_value;

   if(money_per_lot <= 0.0)
      return 0.0;

   double lot =
      risk_money /
      money_per_lot;

   return NormalizeLot(
      symbol,
      lot
   );
}


//+------------------------------------------------------------------+
//| INITIALIZE INDICATORS                                            |
//+------------------------------------------------------------------+
bool InitializeInstance(
   const int index
)
{
   if(index < 0 ||
      index >= MAX_INSTANCES)
   {
      return false;
   }

   string symbol =
      Instances[index].symbol;

   //--- Make symbol available in Market Watch
   if(!SymbolSelect(
         symbol,
         true
      ))
   {
      Print(
         "Failed to select symbol: ",
         symbol
      );

      Instances[index].enabled =
         false;

      return false;
   }

   //--- Reset handles
   Instances[index].handle_fast =
      INVALID_HANDLE;

   Instances[index].handle_slow =
      INVALID_HANDLE;

   Instances[index].handle_rsi =
      INVALID_HANDLE;

   Instances[index].handle_atr =
      INVALID_HANDLE;

   //===============================================================
   // STRATEGY 01 - EMA
   //===============================================================
   if(Instances[index].strategy ==
      STRATEGY_01)
   {
      Instances[index].handle_fast =
         iMA(
            symbol,
            PERIOD_CURRENT,
            Instances[index].period_fast,
            0,
            MODE_EMA,
            PRICE_CLOSE
         );

      Instances[index].handle_slow =
         iMA(
            symbol,
            PERIOD_CURRENT,
            Instances[index].period_slow,
            0,
            MODE_EMA,
            PRICE_CLOSE
         );

      if(Instances[index].handle_fast ==
            INVALID_HANDLE ||
         Instances[index].handle_slow ==
            INVALID_HANDLE)
      {
         Print(
            "Failed to create EMA handles for ",
            symbol
         );

         Instances[index].enabled =
            false;

         return false;
      }
   }

   //===============================================================
   // STRATEGY 02 - RSI
   //===============================================================
   if(Instances[index].strategy ==
      STRATEGY_02)
   {
      Instances[index].handle_rsi =
         iRSI(
            symbol,
            PERIOD_CURRENT,
            Instances[index].rsi_period,
            PRICE_CLOSE
         );

      if(Instances[index].handle_rsi ==
         INVALID_HANDLE)
      {
         Print(
            "Failed to create RSI handle for ",
            symbol
         );

         Instances[index].enabled =
            false;

         return false;
      }
   }

   //===============================================================
   // ATR
   //===============================================================
   Instances[index].handle_atr =
      iATR(
         symbol,
         PERIOD_CURRENT,
         Instances[index].atr_period
      );

   if(Instances[index].handle_atr ==
      INVALID_HANDLE)
   {
      Print(
         "Failed to create ATR handle for ",
         symbol
      );

      Instances[index].enabled =
         false;

      return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| ADD INSTANCE                                                     |
//+------------------------------------------------------------------+
bool AddInstance(
   const bool enabled,
   const ENUM_STRATEGY strategy,
   const string symbol,
   const ulong magic,
   const double lot,
   const int fast_period,
   const int slow_period,
   const int rsi_period,
   const double rsi_buy,
   const double rsi_sell,
   const int breakout_period,
   const int atr_period,
   const double atr_sl,
   const double atr_tp,
   const int max_spread
)
{
   if(InstanceCount >= MAX_INSTANCES)
   {
      Print(
         "Maximum number of instances reached."
      );

      return false;
   }

   int index =
      InstanceCount;

   //--- Configuration
   Instances[index].enabled =
      enabled;

   Instances[index].strategy =
      strategy;

   Instances[index].symbol =
      symbol;

   Instances[index].magic =
      magic;

   Instances[index].lot =
      lot;

   Instances[index].period_fast =
      fast_period;

   Instances[index].period_slow =
      slow_period;

   Instances[index].rsi_period =
      rsi_period;

   Instances[index].rsi_buy =
      rsi_buy;

   Instances[index].rsi_sell =
      rsi_sell;

   Instances[index].breakout_period =
      breakout_period;

   Instances[index].atr_period =
      atr_period;

   Instances[index].atr_sl_multiplier =
      atr_sl;

   Instances[index].atr_tp_multiplier =
      atr_tp;

   Instances[index].max_spread_points =
      max_spread;

   //--- Runtime
   Instances[index].last_bar_time =
      0;

   //--- Handles
   Instances[index].handle_fast =
      INVALID_HANDLE;

   Instances[index].handle_slow =
      INVALID_HANDLE;

   Instances[index].handle_rsi =
      INVALID_HANDLE;

   Instances[index].handle_atr =
      INVALID_HANDLE;

   //--- Always count configured instance
   InstanceCount++;

   //--- Disabled instance does not need indicators
   if(!enabled)
      return true;

   //--- Create indicators
   if(!InitializeInstance(index))
      return false;

   return true;
}


//+------------------------------------------------------------------+
//| SPREAD CHECK                                                     |
//+------------------------------------------------------------------+
bool IsSpreadAllowed(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return false;
   }

   string symbol =
      Instances[index].symbol;

   int max_spread =
      Instances[index].max_spread_points;

   //--- <= 0 means no spread filter
   if(max_spread <= 0)
      return true;

   MqlTick tick;

   if(!SymbolInfoTick(
         symbol,
         tick
      ))
   {
      return false;
   }

   double point =
      SymbolInfoDouble(
         symbol,
         SYMBOL_POINT
      );

   if(point <= 0.0)
      return false;

   double spread =
      (tick.ask - tick.bid) /
      point;

   return (
      spread <=
      max_spread
   );
}


//+------------------------------------------------------------------+
//| NEW BAR CHECK                                                    |
//+------------------------------------------------------------------+
bool IsNewBar(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return false;
   }

   string symbol =
      Instances[index].symbol;

   datetime current_time =
      iTime(
         symbol,
         PERIOD_CURRENT,
         0
      );

   if(current_time <= 0)
      return false;

   if(current_time !=
      Instances[index].last_bar_time)
   {
      Instances[index].last_bar_time =
         current_time;

      return true;
   }

   return false;
}


//+------------------------------------------------------------------+
//| CHECK POSITION                                                   |
//+------------------------------------------------------------------+
bool HasPosition(
   const string symbol,
   const ulong magic
)
{
   int total =
      PositionsTotal();

   for(int i = total - 1;
       i >= 0;
       i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(
            ticket
         ))
      {
         continue;
      }

      string position_symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      ulong position_magic =
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         );

      if(position_symbol == symbol &&
         position_magic == magic)
      {
         return true;
      }
   }

   return false;
}


//+------------------------------------------------------------------+
//| CLOSE OPPOSITE POSITIONS                                         |
//+------------------------------------------------------------------+
void CloseOppositePositions(
   const string symbol,
   const ulong magic,
   const ENUM_POSITION_TYPE desired_type
)
{
   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(
            ticket
         ))
      {
         continue;
      }

      string position_symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      ulong position_magic =
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         );

      if(position_symbol != symbol ||
         position_magic != magic)
      {
         continue;
      }

      ENUM_POSITION_TYPE position_type =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(
            POSITION_TYPE
         );

      if(position_type != desired_type)
      {
         Trade.SetExpertMagicNumber(
            magic
         );

         Trade.SetTypeFillingBySymbol(
            symbol
         );

         if(!Trade.PositionClose(
               ticket
            ))
         {
            Print(
               "Failed to close position #",
               ticket,
               " | Retcode=",
               Trade.ResultRetcode(),
               " | ",
               Trade.ResultRetcodeDescription()
            );
         }
      }
   }
}


//+------------------------------------------------------------------+
//| GET ATR                                                          |
//+------------------------------------------------------------------+
double GetATR(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return 0.0;
   }

   int handle =
      Instances[index].handle_atr;

   if(handle == INVALID_HANDLE)
      return 0.0;

   double buffer[];

   if(CopyBuffer(
         handle,
         0,
         1,
         1,
         buffer
      ) != 1)
   {
      return 0.0;
   }

   return buffer[0];
}


//+------------------------------------------------------------------+
//| GET MINIMUM STOP DISTANCE                                        |
//+------------------------------------------------------------------+
double GetMinimumStopDistance(
   const string symbol
)
{
   double point =
      SymbolInfoDouble(
         symbol,
         SYMBOL_POINT
      );

   long stops_level =
      SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   if(point <= 0.0)
      return 0.0;

   return (
      (double)stops_level *
      point
   );
}


//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return false;
   }

   string symbol =
      Instances[index].symbol;

   ulong magic =
      Instances[index].magic;

   MqlTick tick;

   if(!SymbolInfoTick(
         symbol,
         tick
      ))
   {
      return false;
   }

   double atr =
      GetATR(index);

   if(atr <= 0.0)
      return false;

   double sl_distance =
      atr *
      Instances[index].atr_sl_multiplier;

   double tp_distance =
      atr *
      Instances[index].atr_tp_multiplier;

   //--- Respect broker minimum stop distance
   double minimum_stop =
      GetMinimumStopDistance(
         symbol
      );

   if(sl_distance <
      minimum_stop)
   {
      sl_distance =
         minimum_stop;
   }

   if(tp_distance <
      minimum_stop)
   {
      tp_distance =
         minimum_stop;
   }

   if(sl_distance <= 0.0 ||
      tp_distance <= 0.0)
   {
      return false;
   }

   double lot =
      Instances[index].lot;

   if(InpUseRiskManagement)
   {
      lot =
         CalculateRiskLot(
            symbol,
            sl_distance,
            InpRiskPercent
         );
   }
   else
   {
      lot =
         NormalizeLot(
            symbol,
            lot
         );
   }

   if(lot <= 0.0)
      return false;

   int digits =
      (int)SymbolInfoInteger(
         symbol,
         SYMBOL_DIGITS
      );

   double sl =
      NormalizeDouble(
         tick.ask -
         sl_distance,
         digits
      );

   double tp =
      NormalizeDouble(
         tick.ask +
         tp_distance,
         digits
      );

   Trade.SetExpertMagicNumber(
      magic
   );

   Trade.SetTypeFillingBySymbol(
      symbol
   );

   bool result =
      Trade.Buy(
         lot,
         symbol,
         0.0,
         sl,
         tp,
         "EA10 Strategy BUY"
      );

   if(!result)
   {
      Print(
         "BUY FAILED | ",
         "Symbol=",
         symbol,
         " | Magic=",
         magic,
         " | Retcode=",
         Trade.ResultRetcode(),
         " | ",
         Trade.ResultRetcodeDescription()
      );
   }

   return result;
}


//+------------------------------------------------------------------+
//| OPEN SELL                                                        |
//+------------------------------------------------------------------+
bool OpenSell(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return false;
   }

   string symbol =
      Instances[index].symbol;

   ulong magic =
      Instances[index].magic;

   MqlTick tick;

   if(!SymbolInfoTick(
         symbol,
         tick
      ))
   {
      return false;
   }

   double atr =
      GetATR(index);

   if(atr <= 0.0)
      return false;

   double sl_distance =
      atr *
      Instances[index].atr_sl_multiplier;

   double tp_distance =
      atr *
      Instances[index].atr_tp_multiplier;

   //--- Respect broker minimum stop distance
   double minimum_stop =
      GetMinimumStopDistance(
         symbol
      );

   if(sl_distance <
      minimum_stop)
   {
      sl_distance =
         minimum_stop;
   }

   if(tp_distance <
      minimum_stop)
   {
      tp_distance =
         minimum_stop;
   }

   if(sl_distance <= 0.0 ||
      tp_distance <= 0.0)
   {
      return false;
   }

   double lot =
      Instances[index].lot;

   if(InpUseRiskManagement)
   {
      lot =
         CalculateRiskLot(
            symbol,
            sl_distance,
            InpRiskPercent
         );
   }
   else
   {
      lot =
         NormalizeLot(
            symbol,
            lot
         );
   }

   if(lot <= 0.0)
      return false;

   int digits =
      (int)SymbolInfoInteger(
         symbol,
         SYMBOL_DIGITS
      );

   double sl =
      NormalizeDouble(
         tick.bid +
         sl_distance,
         digits
      );

   double tp =
      NormalizeDouble(
         tick.bid -
         tp_distance,
         digits
      );

   Trade.SetExpertMagicNumber(
      magic
   );

   Trade.SetTypeFillingBySymbol(
      symbol
   );

   bool result =
      Trade.Sell(
         lot,
         symbol,
         0.0,
         sl,
         tp,
         "EA10 Strategy SELL"
      );

   if(!result)
   {
      Print(
         "SELL FAILED | ",
         "Symbol=",
         symbol,
         " | Magic=",
         magic,
         " | Retcode=",
         Trade.ResultRetcode(),
         " | ",
         Trade.ResultRetcodeDescription()
      );
   }

   return result;
}


//+------------------------------------------------------------------+
//| STRATEGY 01 - EMA CROSSOVER                                     |
//+------------------------------------------------------------------+
void ProcessStrategy01(
   const int index
)
{
   int fast_handle =
      Instances[index].handle_fast;

   int slow_handle =
      Instances[index].handle_slow;

   if(fast_handle == INVALID_HANDLE ||
      slow_handle == INVALID_HANDLE)
   {
      return;
   }

   double fast[];
   double slow[];

   //--- Two closed candles
   if(CopyBuffer(
         fast_handle,
         0,
         1,
         2,
         fast
      ) != 2)
   {
      return;
   }

   if(CopyBuffer(
         slow_handle,
         0,
         1,
         2,
         slow
      ) != 2)
   {
      return;
   }

   /*
      CopyBuffer with start position 1 and count 2:

      fast[0] = older closed candle
      fast[1] = latest closed candle

      same for slow
   */

   bool bullish_cross =
      fast[0] <= slow[0] &&
      fast[1] > slow[1];

   bool bearish_cross =
      fast[0] >= slow[0] &&
      fast[1] < slow[1];

   string symbol =
      Instances[index].symbol;

   ulong magic =
      Instances[index].magic;

   //--- BUY
   if(bullish_cross)
   {
      CloseOppositePositions(
         symbol,
         magic,
         POSITION_TYPE_BUY
      );

      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenBuy(index);
   }

   //--- SELL
   else
   if(bearish_cross)
   {
      CloseOppositePositions(
         symbol,
         magic,
         POSITION_TYPE_SELL
      );

      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenSell(index);
   }
}


//+------------------------------------------------------------------+
//| STRATEGY 02 - RSI REVERSAL                                      |
//+------------------------------------------------------------------+
void ProcessStrategy02(
   const int index
)
{
   int handle =
      Instances[index].handle_rsi;

   if(handle == INVALID_HANDLE)
      return;

   double rsi[];

   if(CopyBuffer(
         handle,
         0,
         1,
         1,
         rsi
      ) != 1)
   {
      return;
   }

   double value =
      rsi[0];

   string symbol =
      Instances[index].symbol;

   ulong magic =
      Instances[index].magic;

   double buy_level =
      Instances[index].rsi_buy;

   double sell_level =
      Instances[index].rsi_sell;

   //--- Oversold
   if(value <= buy_level)
   {
      CloseOppositePositions(
         symbol,
         magic,
         POSITION_TYPE_BUY
      );

      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenBuy(index);
   }

   //--- Overbought
   else
   if(value >= sell_level)
   {
      CloseOppositePositions(
         symbol,
         magic,
         POSITION_TYPE_SELL
      );

      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenSell(index);
   }
}


//+------------------------------------------------------------------+
//| STRATEGY 03 - BREAKOUT                                          |
//+------------------------------------------------------------------+
void ProcessStrategy03(
   const int index
)
{
   int period =
      Instances[index].breakout_period;

   if(period < 2)
      return;

   string symbol =
      Instances[index].symbol;

   double highs[];
   double lows[];

   int copied_high =
      CopyHigh(
         symbol,
         PERIOD_CURRENT,
         1,
         period,
         highs
      );

   int copied_low =
      CopyLow(
         symbol,
         PERIOD_CURRENT,
         1,
         period,
         lows
      );

   if(copied_high != period ||
      copied_low != period)
   {
      return;
   }

   double highest =
      highs[0];

   double lowest =
      lows[0];

   for(int i = 1;
       i < period;
       i++)
   {
      if(highs[i] > highest)
         highest = highs[i];

      if(lows[i] < lowest)
         lowest = lows[i];
   }

   MqlTick tick;

   if(!SymbolInfoTick(
         symbol,
         tick
      ))
   {
      return;
   }

   ulong magic =
      Instances[index].magic;

   //--- Breakout BUY
   if(tick.ask > highest)
   {
      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenBuy(index);
   }

   //--- Breakout SELL
   else
   if(tick.bid < lowest)
   {
      if(InpOnePositionPerMagic &&
         HasPosition(
            symbol,
            magic
         ))
      {
         return;
      }

      OpenSell(index);
   }
}


//+------------------------------------------------------------------+
//| PROCESS ONE INSTANCE                                             |
//+------------------------------------------------------------------+
void ProcessInstance(
   const int index
)
{
   if(index < 0 ||
      index >= InstanceCount)
   {
      return;
   }

   if(!Instances[index].enabled)
      return;

   if(!InpEnableTrading)
      return;

   //--- Spread filter
   if(!IsSpreadAllowed(index))
      return;

   //--- New bar filter
   if(InpProcessNewBarOnly)
   {
      if(!IsNewBar(index))
         return;
   }

   switch(
      Instances[index].strategy
   )
   {
      case STRATEGY_01:
         ProcessStrategy01(index);
         break;

      case STRATEGY_02:
         ProcessStrategy02(index);
         break;

      case STRATEGY_03:
         ProcessStrategy03(index);
         break;
   }
}


//+------------------------------------------------------------------+
//| PROCESS ALL INSTANCES                                            |
//+------------------------------------------------------------------+
void ProcessAllInstances()
{
   for(int i = 0;
       i < InstanceCount;
       i++)
   {
      ProcessInstance(i);
   }
}


//+------------------------------------------------------------------+
//| BUILD ALL INSTANCES                                              |
//+------------------------------------------------------------------+
void BuildInstances()
{
   InstanceCount = 0;

   //=================================================================
   // STRATEGY 01 / INSTANCE 01
   //=================================================================

   AddInstance(
      S01_01_Enable,
      STRATEGY_01,
      S01_01_Symbol,
      S01_01_Magic,
      S01_01_Lot,

      S01_01_FastEMA,
      S01_01_SlowEMA,

      14,
      30.0,
      70.0,

      20,

      S01_01_ATRPeriod,
      S01_01_ATR_SL,
      S01_01_ATR_TP,

      S01_01_MaxSpread
   );


   //=================================================================
   // STRATEGY 01 / INSTANCE 02
   //=================================================================

   AddInstance(
      S01_02_Enable,
      STRATEGY_01,
      S01_02_Symbol,
      S01_02_Magic,
      S01_02_Lot,

      S01_02_FastEMA,
      S01_02_SlowEMA,

      14,
      30.0,
      70.0,

      20,

      S01_02_ATRPeriod,
      S01_02_ATR_SL,
      S01_02_ATR_TP,

      S01_02_MaxSpread
   );


   //=================================================================
   // STRATEGY 02 / INSTANCE 01
   //=================================================================

   AddInstance(
      S02_01_Enable,
      STRATEGY_02,
      S02_01_Symbol,
      S02_01_Magic,
      S02_01_Lot,

      20,
      50,

      S02_01_RSI_Period,
      S02_01_RSI_Buy,
      S02_01_RSI_Sell,

      20,

      S02_01_ATRPeriod,
      S02_01_ATR_SL,
      S02_01_ATR_TP,

      S02_01_MaxSpread
   );


   //=================================================================
   // STRATEGY 02 / INSTANCE 02
   //=================================================================

   AddInstance(
      S02_02_Enable,
      STRATEGY_02,
      S02_02_Symbol,
      S02_02_Magic,
      S02_02_Lot,

      20,
      50,

      S02_02_RSI_Period,
      S02_02_RSI_Buy,
      S02_02_RSI_Sell,

      20,

      S02_02_ATRPeriod,
      S02_02_ATR_SL,
      S02_02_ATR_TP,

      S02_02_MaxSpread
   );


   //=================================================================
   // STRATEGY 03 / INSTANCE 01
   //=================================================================

   AddInstance(
      S03_01_Enable,
      STRATEGY_03,
      S03_01_Symbol,
      S03_01_Magic,
      S03_01_Lot,

      20,
      50,

      14,
      30.0,
      70.0,

      S03_01_BreakoutPeriod,

      S03_01_ATRPeriod,
      S03_01_ATR_SL,
      S03_01_ATR_TP,

      S03_01_MaxSpread
   );


   //=================================================================
   // STRATEGY 03 / INSTANCE 02
   //=================================================================

   AddInstance(
      S03_02_Enable,
      STRATEGY_03,
      S03_02_Symbol,
      S03_02_Magic,
      S03_02_Lot,

      20,
      50,

      14,
      30.0,
      70.0,

      S03_02_BreakoutPeriod,

      S03_02_ATRPeriod,
      S03_02_ATR_SL,
      S03_02_ATR_TP,

      S03_02_MaxSpread
   );
}


//+------------------------------------------------------------------+
//| RELEASE HANDLES                                                  |
//+------------------------------------------------------------------+
void ReleaseInstanceHandles(
   const int index
)
{
   if(index < 0 ||
      index >= MAX_INSTANCES)
   {
      return;
   }

   if(Instances[index].handle_fast !=
      INVALID_HANDLE)
   {
      IndicatorRelease(
         Instances[index].handle_fast
      );

      Instances[index].handle_fast =
         INVALID_HANDLE;
   }

   if(Instances[index].handle_slow !=
      INVALID_HANDLE)
   {
      IndicatorRelease(
         Instances[index].handle_slow
      );

      Instances[index].handle_slow =
         INVALID_HANDLE;
   }

   if(Instances[index].handle_rsi !=
      INVALID_HANDLE)
   {
      IndicatorRelease(
         Instances[index].handle_rsi
      );

      Instances[index].handle_rsi =
         INVALID_HANDLE;
   }

   if(Instances[index].handle_atr !=
      INVALID_HANDLE)
   {
      IndicatorRelease(
         Instances[index].handle_atr
      );

      Instances[index].handle_atr =
         INVALID_HANDLE;
   }
}


//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   BuildInstances();

   if(InstanceCount <= 0)
   {
      Print(
         "ERROR: No strategy instances configured."
      );

      return INIT_FAILED;
   }

   //--- Configure timer for multicurrency execution
   int timer_seconds =
      InpTimerSeconds;

   if(timer_seconds < 1)
      timer_seconds = 1;

   if(!EventSetTimer(
         timer_seconds
      ))
   {
      Print(
         "WARNING: Failed to create timer. ",
         "Error=",
         GetLastError()
      );
   }

   int enabled_count = 0;

   for(int i = 0;
       i < InstanceCount;
       i++)
   {
      if(Instances[i].enabled)
         enabled_count++;
   }

   Print(
      "========================================"
   );

   Print(
      "EA10 INITIALIZED"
   );

   Print(
      "Total Instances: ",
      InstanceCount
   );

   Print(
      "Enabled Instances: ",
      enabled_count
   );

   Print(
      "Timer: ",
      timer_seconds,
      " second(s)"
   );

   Print(
      "========================================"
   );

   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(
   const int reason
)
{
   EventKillTimer();

   for(int i = 0;
       i < InstanceCount;
       i++)
   {
      ReleaseInstanceHandles(i);
   }

   Print(
      "EA10 deinitialized. Reason=",
      reason
   );
}


//+------------------------------------------------------------------+
//| TICK EVENT                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process immediately when chart receives a tick
   ProcessAllInstances();
}


//+------------------------------------------------------------------+
//| TIMER EVENT                                                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   //--- Process all configured symbols
   //--- This is what allows multicurrency operation
   ProcessAllInstances();
}


//+------------------------------------------------------------------+