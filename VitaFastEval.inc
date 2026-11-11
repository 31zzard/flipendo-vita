// A faster way through the commonest UnrealScript statements (apply_fixes.sh #202), included in VM/Frame.cpp before Frame::RunExpr.
//
// Frame::RunExpr is a stack machine: every expression node is pushed on vmstack.expr, popped, and dispatched by its type once per
// pass (two or three passes for a node with children), and every value goes through vmstack.value (a 48-byte ExpressionValue
// placement-new'd, moved out, destroyed). On the Vita that is ~2.4 us a statement: HP1's level tick spends 6-12 ms a frame in it.
//
// Here a statement whose whole tree is made of the node types below is evaluated by plain recursion instead. Each node does what
// its RunExpr case does, in the same order:
//   - children in RunExpr's order: function and operator arguments left to right, with the context set to 'self' while they are
//     evaluated, the call made on the context; a Let's right side before its left side; a StructCmp's Value2 before Value1;
//   - a Context whose object is None marks the statement AccessedNone and gives Nothing, and the statement goes on (a later
//     JumpIfNot or Return still sets its own result over it, as in RunExpr);
//   - natives and script functions are called through Frame::Call with the same argument values (variables stay variables, so
//     out parameters are written back the same way);
//   - Frame::StepExpression is the call node when a call is made (what LogAccessedNone reports in Frame::Call).
// A statement with any other node (iterators, switch, labels, arrays, strings and their conversions, latent state code helpers,
// ...) runs in RunExpr as before. render.cfg fast_eval=0: RunExpr for everything. fast_eval_check=1: statements without side
// effects (no assignment, only native operators without out parameters, no script calls) are evaluated both ways and compared
// (log 'VitaFastEval: N statements compared with RunExpr, M differ').

#ifdef __vita__

namespace
{
	enum : int8_t { VitaFastNo = 0, VitaFastYes = 1 };
	enum { VitaFastMaxArgs = 16 };

	int VitaFastEvalMode()
	{
		static const int mode = VitaConfigInt("fast_eval", 1);
		return mode;
	}
	bool VitaFastStats()
	{
		static const bool on = VitaConfigInt("fast_eval_stats", 0) != 0;
		return on;
	}
	bool VitaFastEvalCheck()
	{
		static const bool check = VitaConfigInt("fast_eval_check", 0) != 0;
		return check;
	}

	uint8_t vitaFastBlocker = 0;   // the type of the last node found that VitaFastEval does not take (the statistics below)

	// Can this node, and everything under it, be evaluated by VitaFastEval?
	bool VitaFastNode(Expression* e)
	{
		if (!e)
			return false;
		if (e->VitaFast >= 0)
		{
			if (e->VitaFast != VitaFastYes)
				vitaFastBlocker = e->VitaFastWhy;
			return e->VitaFast == VitaFastYes;
		}
		bool ok = false;
		auto args = [](const Array<Expression*>& list)
		{
			if (list.size() > VitaFastMaxArgs)
				return false;
			for (Expression* a : list)
				if (!VitaFastNode(a))
					return false;
			return true;
		};
		switch (e->Type)
		{
		case ExpressionType::LocalVariable:
		case ExpressionType::InstanceVariable:
		case ExpressionType::DefaultVariable:
		case ExpressionType::Self:
		case ExpressionType::IntConst:
		case ExpressionType::FloatConst:
		case ExpressionType::ObjectConst:
		case ExpressionType::NameConst:
		case ExpressionType::RotationConst:
		case ExpressionType::VectorConst:
		case ExpressionType::ByteConst:
		case ExpressionType::IntZero:
		case ExpressionType::IntOne:
		case ExpressionType::True:
		case ExpressionType::False:
		case ExpressionType::NoObject:
		case ExpressionType::IntConstByte:
		case ExpressionType::Nothing:
			ok = true;
			break;
		case ExpressionType::BoolVariable: ok = VitaFastNode(static_cast<BoolVariableExpression*>(e)->Variable); break;
		case ExpressionType::Skip: ok = VitaFastNode(static_cast<SkipExpression*>(e)->Value); break;
		case ExpressionType::DynamicCast: ok = static_cast<DynamicCastExpression*>(e)->Class && VitaFastNode(static_cast<DynamicCastExpression*>(e)->Value); break;
		case ExpressionType::StructMember: ok = static_cast<StructMemberExpression*>(e)->Field && VitaFastNode(static_cast<StructMemberExpression*>(e)->Value); break;
		case ExpressionType::Context:
			ok = VitaFastNode(static_cast<ContextExpression*>(e)->ObjectExpr) && VitaFastNode(static_cast<ContextExpression*>(e)->ContextExpr);
			break;
		case ExpressionType::ArrayElement:
			ok = VitaFastNode(static_cast<ArrayElementExpression*>(e)->Index) && VitaFastNode(static_cast<ArrayElementExpression*>(e)->Array);
			break;
		case ExpressionType::Let: ok = VitaFastNode(static_cast<LetExpression*>(e)->LeftSide) && VitaFastNode(static_cast<LetExpression*>(e)->RightSide); break;
		case ExpressionType::LetBool: ok = VitaFastNode(static_cast<LetBoolExpression*>(e)->LeftSide) && VitaFastNode(static_cast<LetBoolExpression*>(e)->RightSide); break;
		case ExpressionType::StructCmpEq: ok = VitaFastNode(static_cast<StructCmpEqExpression*>(e)->Value1) && VitaFastNode(static_cast<StructCmpEqExpression*>(e)->Value2); break;
		case ExpressionType::StructCmpNe: ok = VitaFastNode(static_cast<StructCmpNeExpression*>(e)->Value1) && VitaFastNode(static_cast<StructCmpNeExpression*>(e)->Value2); break;
		case ExpressionType::ByteToInt: ok = VitaFastNode(static_cast<ByteToIntExpression*>(e)->Value); break;
		case ExpressionType::ByteToBool: ok = VitaFastNode(static_cast<ByteToBoolExpression*>(e)->Value); break;
		case ExpressionType::ByteToFloat: ok = VitaFastNode(static_cast<ByteToFloatExpression*>(e)->Value); break;
		case ExpressionType::IntToByte: ok = VitaFastNode(static_cast<IntToByteExpression*>(e)->Value); break;
		case ExpressionType::IntToBool: ok = VitaFastNode(static_cast<IntToBoolExpression*>(e)->Value); break;
		case ExpressionType::IntToFloat: ok = VitaFastNode(static_cast<IntToFloatExpression*>(e)->Value); break;
		case ExpressionType::BoolToByte: ok = VitaFastNode(static_cast<BoolToByteExpression*>(e)->Value); break;
		case ExpressionType::BoolToInt: ok = VitaFastNode(static_cast<BoolToIntExpression*>(e)->Value); break;
		case ExpressionType::BoolToFloat: ok = VitaFastNode(static_cast<BoolToFloatExpression*>(e)->Value); break;
		case ExpressionType::FloatToByte: ok = VitaFastNode(static_cast<FloatToByteExpression*>(e)->Value); break;
		case ExpressionType::FloatToInt: ok = VitaFastNode(static_cast<FloatToIntExpression*>(e)->Value); break;
		case ExpressionType::FloatToBool: ok = VitaFastNode(static_cast<FloatToBoolExpression*>(e)->Value); break;
		case ExpressionType::ObjectToBool: ok = VitaFastNode(static_cast<ObjectToBoolExpression*>(e)->Value); break;
		case ExpressionType::NativeFunction:
		{
			auto f = static_cast<NativeFunctionExpression*>(e);
			const int idx = f->nativeindex;
			if (idx == 130 || idx == 132)
				ok = f->Args.size() >= 2 && VitaFastNode(f->Args[0]) && VitaFastNode(f->Args[1]);
			else
				ok = idx > 0 && (size_t)idx < NativeFunctions::FuncByIndex.size() && NativeFunctions::FuncByIndex[idx] && args(f->Args);
			break;
		}
		case ExpressionType::FinalFunction: ok = static_cast<FinalFunctionExpression*>(e)->Func && args(static_cast<FinalFunctionExpression*>(e)->Args); break;
		case ExpressionType::VirtualFunction: ok = args(static_cast<VirtualFunctionExpression*>(e)->Args); break;
		case ExpressionType::GlobalFunction: ok = args(static_cast<GlobalFunctionExpression*>(e)->Args); break;
		default:
			ok = false;
			vitaFastBlocker = (uint8_t)e->Type;
			break;
		}
		e->VitaFast = ok ? VitaFastYes : VitaFastNo;
		if (!ok)
			e->VitaFastWhy = vitaFastBlocker;
		return ok;
	}

	// A statement VitaFastEval runs
	bool VitaFastStatement(Expression* s)
	{
		switch (s->Type)
		{
		case ExpressionType::Let:
		case ExpressionType::LetBool:
		case ExpressionType::NativeFunction:
		case ExpressionType::FinalFunction:
		case ExpressionType::VirtualFunction:
		case ExpressionType::GlobalFunction:
		case ExpressionType::Nothing:
			return VitaFastNode(s);
		case ExpressionType::JumpIfNot:
			return VitaFastNode(static_cast<JumpIfNotExpression*>(s)->Condition);
		case ExpressionType::Return:
			return !static_cast<ReturnExpression*>(s)->Value || VitaFastNode(static_cast<ReturnExpression*>(s)->Value);
		case ExpressionType::Jump:
			return true;
		default:
			vitaFastBlocker = (uint8_t)s->Type;
			return false;
		}
	}

	// Side effect free: no assignment, no script call, only natives without out parameters (fast_eval_check compares these)
	bool VitaFastPure(Expression* e)
	{
		if (!e)
			return true;
		switch (e->Type)
		{
		case ExpressionType::Let:
		case ExpressionType::LetBool:
		case ExpressionType::FinalFunction:
		case ExpressionType::VirtualFunction:
		case ExpressionType::GlobalFunction:
			return false;
		case ExpressionType::NativeFunction:
		{
			auto f = static_cast<NativeFunctionExpression*>(e);
			if (f->nativeindex != 130 && f->nativeindex != 132)
			{
				UFunction* func = NativeFunctions::FuncByIndex[f->nativeindex];
				if (!AllFlags(func->FuncFlags, FunctionFlags::Operator))
					return false;
				for (UProperty* p : func->Properties)
					if (AllFlags(p->PropFlags, PropertyFlags::OutParm))
						return false;
			}
			for (Expression* a : f->Args)
				if (!VitaFastPure(a))
					return false;
			return true;
		}
		case ExpressionType::BoolVariable: return VitaFastPure(static_cast<BoolVariableExpression*>(e)->Variable);
		case ExpressionType::Skip: return VitaFastPure(static_cast<SkipExpression*>(e)->Value);
		case ExpressionType::DynamicCast: return VitaFastPure(static_cast<DynamicCastExpression*>(e)->Value);
		case ExpressionType::StructMember: return VitaFastPure(static_cast<StructMemberExpression*>(e)->Value);
		case ExpressionType::Context: return VitaFastPure(static_cast<ContextExpression*>(e)->ObjectExpr) && VitaFastPure(static_cast<ContextExpression*>(e)->ContextExpr);
		case ExpressionType::ArrayElement: return VitaFastPure(static_cast<ArrayElementExpression*>(e)->Index) && VitaFastPure(static_cast<ArrayElementExpression*>(e)->Array);
		case ExpressionType::StructCmpEq: return VitaFastPure(static_cast<StructCmpEqExpression*>(e)->Value1) && VitaFastPure(static_cast<StructCmpEqExpression*>(e)->Value2);
		case ExpressionType::StructCmpNe: return VitaFastPure(static_cast<StructCmpNeExpression*>(e)->Value1) && VitaFastPure(static_cast<StructCmpNeExpression*>(e)->Value2);
		case ExpressionType::ByteToInt: return VitaFastPure(static_cast<ByteToIntExpression*>(e)->Value);
		case ExpressionType::ByteToBool: return VitaFastPure(static_cast<ByteToBoolExpression*>(e)->Value);
		case ExpressionType::ByteToFloat: return VitaFastPure(static_cast<ByteToFloatExpression*>(e)->Value);
		case ExpressionType::IntToByte: return VitaFastPure(static_cast<IntToByteExpression*>(e)->Value);
		case ExpressionType::IntToBool: return VitaFastPure(static_cast<IntToBoolExpression*>(e)->Value);
		case ExpressionType::IntToFloat: return VitaFastPure(static_cast<IntToFloatExpression*>(e)->Value);
		case ExpressionType::BoolToByte: return VitaFastPure(static_cast<BoolToByteExpression*>(e)->Value);
		case ExpressionType::BoolToInt: return VitaFastPure(static_cast<BoolToIntExpression*>(e)->Value);
		case ExpressionType::BoolToFloat: return VitaFastPure(static_cast<BoolToFloatExpression*>(e)->Value);
		case ExpressionType::FloatToByte: return VitaFastPure(static_cast<FloatToByteExpression*>(e)->Value);
		case ExpressionType::FloatToInt: return VitaFastPure(static_cast<FloatToIntExpression*>(e)->Value);
		case ExpressionType::FloatToBool: return VitaFastPure(static_cast<FloatToBoolExpression*>(e)->Value);
		case ExpressionType::ObjectToBool: return VitaFastPure(static_cast<ObjectToBoolExpression*>(e)->Value);
		default:
			return true;
		}
	}

	struct VitaFastState
	{
		UObject* self;
		void* variables;
		ExpressionEvalResult* result;
	};

	ExpressionValue VitaFastEval(Expression* e, UObject* context, VitaFastState& s);

	// The arguments of a call, evaluated left to right with the context set to self (RunExpr's PushContext(self))
	struct VitaFastArgs
	{
		alignas(ExpressionValue) char buffer[VitaFastMaxArgs * sizeof(ExpressionValue)];
		size_t count = 0;
		ExpressionValue* data() { return reinterpret_cast<ExpressionValue*>(buffer); }
		VitaFastArgs(const Array<Expression*>& args, VitaFastState& s)
		{
			for (Expression* a : args)
			{
				new (buffer + count * sizeof(ExpressionValue)) ExpressionValue(VitaFastEval(a, s.self, s));
				count++;
			}
		}
		~VitaFastArgs()
		{
			for (size_t i = 0; i < count; i++)
				data()[i].~ExpressionValue();
		}
		ArrayView<ExpressionValue> View() { return ArrayView<ExpressionValue>(data(), count); }
	};

	ExpressionValue VitaFastEval(Expression* e, UObject* context, VitaFastState& s)
	{
		switch (e->Type)
		{
		case ExpressionType::LocalVariable:
			return ExpressionValue::Variable(s.variables, static_cast<LocalVariableExpression*>(e)->Variable);
		case ExpressionType::InstanceVariable:
			return ExpressionValue::Variable(context->PropertyData.Data, static_cast<InstanceVariableExpression*>(e)->Variable);
		case ExpressionType::DefaultVariable:
			if (UObject::TryCast<UClass>(context))
				return ExpressionValue::Variable(context->PropertyData.Data, static_cast<DefaultVariableExpression*>(e)->Variable);
			return ExpressionValue::Variable(context->Class->GetDefaultObject<UObject>()->PropertyData.Data, static_cast<DefaultVariableExpression*>(e)->Variable);
		case ExpressionType::Self: return ExpressionValue::ObjectValue(s.self);
		case ExpressionType::IntConst: return ExpressionValue::IntValue(static_cast<IntConstExpression*>(e)->Value);
		case ExpressionType::FloatConst: return ExpressionValue::FloatValue(static_cast<FloatConstExpression*>(e)->Value);
		case ExpressionType::ObjectConst: return ExpressionValue::ObjectValue(static_cast<ObjectConstExpression*>(e)->Object);
		case ExpressionType::NameConst: return ExpressionValue::NameValue(static_cast<NameConstExpression*>(e)->Value);
		case ExpressionType::RotationConst:
		{
			auto r = static_cast<RotationConstExpression*>(e);
			return ExpressionValue::RotatorValue({ r->Pitch, r->Yaw, r->Roll });
		}
		case ExpressionType::VectorConst:
		{
			auto v = static_cast<VectorConstExpression*>(e);
			return ExpressionValue::VectorValue({ v->X, v->Y, v->Z });
		}
		case ExpressionType::ByteConst: return ExpressionValue::ByteValue(static_cast<ByteConstExpression*>(e)->Value);
		case ExpressionType::IntZero: return ExpressionValue::IntValue(0);
		case ExpressionType::IntOne: return ExpressionValue::IntValue(1);
		case ExpressionType::True: return ExpressionValue::BoolValue(true);
		case ExpressionType::False: return ExpressionValue::BoolValue(false);
		case ExpressionType::NoObject: return ExpressionValue::ObjectValue(nullptr);
		case ExpressionType::IntConstByte: return ExpressionValue::ByteValue(static_cast<IntConstByteExpression*>(e)->Value);
		case ExpressionType::Nothing: return ExpressionValue::NothingValue();
		case ExpressionType::BoolVariable: return VitaFastEval(static_cast<BoolVariableExpression*>(e)->Variable, context, s);
		case ExpressionType::Skip: return VitaFastEval(static_cast<SkipExpression*>(e)->Value, context, s);
		case ExpressionType::DynamicCast:
		{
			UObject* value = VitaFastEval(static_cast<DynamicCastExpression*>(e)->Value, context, s).ToObject();
			if (value && !value->IsA(static_cast<DynamicCastExpression*>(e)->Class->Name))
				value = nullptr;
			return ExpressionValue::ObjectValue(value);
		}
		case ExpressionType::StructMember:
		{
			ExpressionValue val = VitaFastEval(static_cast<StructMemberExpression*>(e)->Value, context, s);
			return val.Member(static_cast<StructMemberExpression*>(e)->Field);
		}
		case ExpressionType::Context:
		{
			auto c = static_cast<ContextExpression*>(e);
			UObject* newContext = VitaFastEval(c->ObjectExpr, context, s).ToObject();
			if (!newContext)
			{
				s.result->Result = StatementResult::AccessedNone;
				return ExpressionValue::NothingValue();
			}
			return VitaFastEval(c->ContextExpr, newContext, s);
		}
		case ExpressionType::ArrayElement:
		{
			// RunExpr pushes Index then Array: the array is evaluated first
			auto a = static_cast<ArrayElementExpression*>(e);
			ExpressionValue arrayval = VitaFastEval(a->Array, context, s);
			const int index = VitaFastEval(a->Index, context, s).ToInt();
			if (arrayval.IsVariable())
				return arrayval.ItemAt(index);
			Frame::ThrowException("Array is not a variable in ArrayElementExpression");
			return ExpressionValue::NothingValue();
		}
		case ExpressionType::Let:
		case ExpressionType::LetBool:
		{
			Expression* left = e->Type == ExpressionType::Let ? static_cast<LetExpression*>(e)->LeftSide : static_cast<LetBoolExpression*>(e)->LeftSide;
			Expression* right = e->Type == ExpressionType::Let ? static_cast<LetExpression*>(e)->RightSide : static_cast<LetBoolExpression*>(e)->RightSide;
			ExpressionValue rvalue = VitaFastEval(right, context, s);
			ExpressionValue lvalue = VitaFastEval(left, context, s);
			if (lvalue.GetType() != ExpressionValueType::Nothing)
			{
				lvalue.Store(rvalue);
				return lvalue;
			}
			return rvalue;
		}
		case ExpressionType::StructCmpEq:
		case ExpressionType::StructCmpNe:
		{
			const bool eq = e->Type == ExpressionType::StructCmpEq;
			Expression* v1 = eq ? static_cast<StructCmpEqExpression*>(e)->Value1 : static_cast<StructCmpNeExpression*>(e)->Value1;
			Expression* v2 = eq ? static_cast<StructCmpEqExpression*>(e)->Value2 : static_cast<StructCmpNeExpression*>(e)->Value2;
			ExpressionValue val2 = VitaFastEval(v2, context, s);
			ExpressionValue val1 = VitaFastEval(v1, context, s);
			const bool same = val1.IsEqual(val2);
			return ExpressionValue::BoolValue(eq ? same : !same);
		}
		case ExpressionType::ByteToInt: return ExpressionValue::IntValue(VitaFastEval(static_cast<ByteToIntExpression*>(e)->Value, context, s).ToByte());
		case ExpressionType::ByteToBool: return ExpressionValue::BoolValue(VitaFastEval(static_cast<ByteToBoolExpression*>(e)->Value, context, s).ToByte() != 0);
		case ExpressionType::ByteToFloat: return ExpressionValue::FloatValue(VitaFastEval(static_cast<ByteToFloatExpression*>(e)->Value, context, s).ToByte());
		case ExpressionType::IntToByte: return ExpressionValue::ByteValue(VitaFastEval(static_cast<IntToByteExpression*>(e)->Value, context, s).ToInt());
		case ExpressionType::IntToBool: return ExpressionValue::BoolValue(VitaFastEval(static_cast<IntToBoolExpression*>(e)->Value, context, s).ToInt());
		case ExpressionType::IntToFloat: return ExpressionValue::FloatValue((float)VitaFastEval(static_cast<IntToFloatExpression*>(e)->Value, context, s).ToInt());
		case ExpressionType::BoolToByte: return ExpressionValue::ByteValue(VitaFastEval(static_cast<BoolToByteExpression*>(e)->Value, context, s).ToBool());
		case ExpressionType::BoolToInt: return ExpressionValue::IntValue(VitaFastEval(static_cast<BoolToIntExpression*>(e)->Value, context, s).ToBool());
		case ExpressionType::BoolToFloat: return ExpressionValue::FloatValue(VitaFastEval(static_cast<BoolToFloatExpression*>(e)->Value, context, s).ToBool());
		case ExpressionType::FloatToByte: return ExpressionValue::ByteValue((uint8_t)VitaFastEval(static_cast<FloatToByteExpression*>(e)->Value, context, s).ToFloat());
		case ExpressionType::FloatToInt: return ExpressionValue::IntValue((int)VitaFastEval(static_cast<FloatToIntExpression*>(e)->Value, context, s).ToFloat());
		case ExpressionType::FloatToBool: return ExpressionValue::BoolValue(VitaFastEval(static_cast<FloatToBoolExpression*>(e)->Value, context, s).ToFloat());
		case ExpressionType::ObjectToBool: return ExpressionValue::BoolValue(VitaFastEval(static_cast<ObjectToBoolExpression*>(e)->Value, context, s).ToObject() != nullptr);
		case ExpressionType::NativeFunction:
		{
			auto f = static_cast<NativeFunctionExpression*>(e);
			if (f->nativeindex == 130)   // &&: the right side only when the left is true
			{
				if (!VitaFastEval(f->Args[0], s.self, s).ToBool())
					return ExpressionValue::BoolValue(false);
				return ExpressionValue::BoolValue(VitaFastEval(f->Args[1], s.self, s).ToBool());
			}
			if (f->nativeindex == 132)   // ||: the right side only when the left is false
			{
				if (VitaFastEval(f->Args[0], s.self, s).ToBool())
					return ExpressionValue::BoolValue(true);
				return ExpressionValue::BoolValue(VitaFastEval(f->Args[1], s.self, s).ToBool());
			}
			UFunction* func = NativeFunctions::FuncByIndex[f->nativeindex];
			if (func->VitaFastOp == 1 && context)
			{
				// An operator: Frame::Call's frameless way (vita-fastop-call) with the arguments evaluated straight into its array.
				// Only for the usual layout: the parameters in order, the return value (if any) last, no more arguments than
				// parameters; else Frame::Call itself.
				int parms = 0, ret = -1;
				bool usual = true;
				for (UProperty* prop : func->Properties)
				{
					if (!AllFlags(prop->PropFlags, PropertyFlags::Parm))
						continue;
					if (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm))
					{
						if (ret >= 0)
							usual = false;
						ret = parms;
					}
					else if (ret >= 0)
						usual = false;
					parms++;
				}
				const int inputs = ret >= 0 ? parms - 1 : parms;
				if (usual && parms <= 8 && (int)f->Args.size() <= inputs)
				{
					alignas(ExpressionValue) char buffer[8 * sizeof(ExpressionValue)];
					ExpressionValue* frameArgs = reinterpret_cast<ExpressionValue*>(buffer);
					int made = 0;
					struct Destroy
					{
						ExpressionValue* values; int* count;
						~Destroy() { for (int i = 0; i < *count; i++) values[i].~ExpressionValue(); }
					} destroy{ frameArgs, &made };
					for (Expression* a : f->Args)   // left to right, the context set to self (RunExpr's order)
					{
						new (frameArgs + made) ExpressionValue(VitaFastEval(a, s.self, s));
						made++;
					}
					int index = 0;
					for (UProperty* prop : func->Properties)
					{
						if (!AllFlags(prop->PropFlags, PropertyFlags::Parm))
							continue;
						if (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm))
						{
							new (frameArgs + made) ExpressionValue(ExpressionValue::PropertyValue(prop));
							made++;
						}
						else if (index < (int)f->Args.size())
						{
							if (frameArgs[index].GetType() == ExpressionValueType::Nothing && AllFlags(prop->PropFlags, PropertyFlags::OutParm) && !AllFlags(prop->PropFlags, PropertyFlags::OptionalParm))
								frameArgs[index] = ExpressionValue::DefaultValue(prop);
						}
						else
						{
							new (frameArgs + made) ExpressionValue(ExpressionValue::NothingValue());
							made++;
						}
						index++;
					}
					Frame::StepExpression = e;
					try
					{
						NativeFunctions::NativeByIndex[func->NativeFuncIndex](context, frameArgs);
					}
					catch (const std::exception& ex)
					{
						LogMessage(std::string("Script error: ") + ex.what());
						return ExpressionValue::NothingValue();
					}
					catch (...)
					{
						LogMessage("Script error: Unknown error");
						return ExpressionValue::NothingValue();
					}
					return ret >= 0 ? frameArgs[ret] : ExpressionValue::NothingValue();
				}
			}
			VitaFastArgs args(f->Args, s);
			Frame::StepExpression = e;
			return Frame::Call(func, context, args.View());
		}
		case ExpressionType::FinalFunction:
		{
			auto f = static_cast<FinalFunctionExpression*>(e);
			VitaFastArgs args(f->Args, s);
			Frame::StepExpression = e;
			return Frame::Call(f->Func, context, args.View());
		}
		case ExpressionType::VirtualFunction:
		{
			auto f = static_cast<VirtualFunctionExpression*>(e);
			VitaFastArgs args(f->Args, s);
			Frame::StepExpression = e;
			UClass* contextClass = UObject::TryCast<UClass>(context);
			if (!contextClass)
				contextClass = context->Class;
			if (UFunction* func = VitaFindFunction(contextClass, context->GetStateName(), f->Name))
				return Frame::Call(func, context, args.View());
			NameString stateName = context->GetStateName();
			for (UClass* cls = contextClass; cls != nullptr; cls = static_cast<UClass*>(cls->BaseStruct))
				if (UState* state = cls->GetState(stateName))
					if (UFunction* func = state->GetFunction(f->Name))
						return Frame::Call(func, context, args.View());
			for (UClass* cls = contextClass; cls != nullptr; cls = static_cast<UClass*>(cls->BaseStruct))
				if (UFunction* func = cls->GetFunction(f->Name))
					return Frame::Call(func, context, args.View());
			Frame::ThrowException("Script virtual function " + f->Name.ToString() + " not found!");
			return ExpressionValue::NothingValue();
		}
		case ExpressionType::GlobalFunction:
		{
			auto f = static_cast<GlobalFunctionExpression*>(e);
			VitaFastArgs args(f->Args, s);
			Frame::StepExpression = e;
			UClass* contextClass = UObject::TryCast<UClass>(context);
			if (!contextClass)
				contextClass = context->Class;
			for (UClass* cls = contextClass; cls != nullptr; cls = static_cast<UClass*>(cls->BaseStruct))
				if (UFunction* func = cls->GetFunction(f->Name))
					return Frame::Call(func, context, args.View());
			Frame::ThrowException("Script global function " + f->Name.ToString() + " not found!");
			return ExpressionValue::NothingValue();
		}
		default:
			Frame::ThrowException("VitaFastEval: an expression it does not take");
			return ExpressionValue::NothingValue();
		}
	}

	// The whole statement, with RunExpr's result (made in the caller's fresh result)
	void VitaFastRunStatement(Expression* statement, UObject* self, UObject* context, void* variables, ExpressionEvalResult& result)
	{
		VitaFastState s{ self, variables, &result };
		Frame::StepExpression = statement;
		switch (statement->Type)
		{
		case ExpressionType::JumpIfNot:
		{
			auto j = static_cast<JumpIfNotExpression*>(statement);
			if (!VitaFastEval(j->Condition, context, s).ToBool())
			{
				result.Result = StatementResult::Jump;
				result.JumpAddress = j->Offset;
			}
			return;   // the condition is popped: no value left (RunExpr's result.Value stays Nothing)
		}
		case ExpressionType::Return:
		{
			auto r = static_cast<ReturnExpression*>(statement);
			ExpressionValue value = r->Value ? VitaFastEval(r->Value, context, s) : ExpressionValue::NothingValue();
			result.Result = StatementResult::Return;
			result.Value = std::move(value);
			return;
		}
		case ExpressionType::Jump:
			result.Result = StatementResult::Jump;
			result.JumpAddress = static_cast<JumpExpression*>(statement)->Offset;
			result.Value = ExpressionValue::NothingValue();
			return;
		default:
			result.Value = VitaFastEval(statement, context, s);
			return;
		}
	}

	bool VitaFastSameResult(ExpressionEvalResult& a, ExpressionEvalResult& b)
	{
		if (a.Result != b.Result || a.JumpAddress != b.JumpAddress || a.Value.GetType() != b.Value.GetType())
			return false;
		if (a.Value.GetType() == ExpressionValueType::Nothing)
			return true;
		return a.Value.IsEqual(b.Value);
	}

	bool vitaFastOff = false;   // fast_eval_check: RunExpr's own way for the comparison
}

// Frame::Run's way in: the statement done here straight into Run's result (no temporary result moved through RunExpr); false: not taken
static bool VitaFastRunInto(Expression* statement, UObject* self, UObject* context, void* variables, ExpressionEvalResult& result)
{
	if (statement->VitaFastStmt != 1 || vitaFastOff || !VitaFastEvalMode() || VitaFastEvalCheck() || VitaFastStats())
		return false;
	VitaFastRunStatement(statement, self, context, variables, result);
	return true;
}

// RunExpr's start: 0 = RunExpr runs it, 1 = done here (out), 2 = fast_eval_check: done here (out) and RunExpr must run it too, for
// VitaFastCompare (only statements without side effects)
static int VitaFastTry(Expression* statementExpr, UObject* self, UObject* context, void* variables, ExpressionEvalResult& out)
{
	if (vitaFastOff || !VitaFastEvalMode())
		return 0;
	if (statementExpr->VitaFastStmt < 0)
	{
		vitaFastBlocker = 0;
		statementExpr->VitaFastStmt = VitaFastStatement(statementExpr) ? 1 : 0;
		statementExpr->VitaFastWhy = vitaFastBlocker;
	}
	if (VitaFastStats())   // fast_eval_stats=1: what keeps statements in RunExpr, weighted by how often they run
	{
		static unsigned counts[256] = {}, fast = 0, slow = 0;
		if (statementExpr->VitaFastStmt == 1)
			fast++;
		else
		{
			slow++;
			counts[statementExpr->VitaFastWhy]++;
		}
		if ((fast + slow) % 200000 == 0)
		{
			std::string text = "VitaFastEval: " + std::to_string(fast) + " statements the fast way, " + std::to_string(slow) + " in RunExpr; kept there by (expression type: statements):";
			for (int n = 0; n < 10; n++)
			{
				int best = -1;
				for (int t = 0; t < 256; t++)
					if (counts[t] && (best < 0 || counts[t] > counts[best]))
						best = t;
				if (best < 0)
					break;
				text += " " + std::to_string(best) + ": " + std::to_string(counts[best]) + ";";
				counts[best] = 0;
			}
			LogMessage(text);
			std::fill(std::begin(counts), std::end(counts), 0u);
			fast = slow = 0;
		}
	}
	if (statementExpr->VitaFastStmt != 1)
		return 0;
	VitaFastRunStatement(statementExpr, self, context, variables, out);
	if (!VitaFastEvalCheck())
		return 1;
	Expression* checked = statementExpr->Type == ExpressionType::JumpIfNot ? static_cast<JumpIfNotExpression*>(statementExpr)->Condition :
		statementExpr->Type == ExpressionType::Return ? static_cast<ReturnExpression*>(statementExpr)->Value : statementExpr;
	const bool comparable = (statementExpr->Type == ExpressionType::JumpIfNot || statementExpr->Type == ExpressionType::Return ||
		statementExpr->Type == ExpressionType::Jump || statementExpr->Type == ExpressionType::NativeFunction) && VitaFastPure(checked);
	return comparable ? 2 : 1;
}

static void VitaFastCompare(Expression* statementExpr, ExpressionEvalResult& fast, ExpressionEvalResult& normal)
{
	static unsigned checkedCount = 0, wrong = 0;
	checkedCount++;
	const bool same = VitaFastSameResult(fast, normal);
	if (!same)
		wrong++;
	if (checkedCount % 20000 == 0 || (!same && wrong < 30))
		LogMessage("VitaFastEval: " + std::to_string(checkedCount) + " statements compared with RunExpr, " + std::to_string(wrong) + " differ" +
			(same ? std::string() : " (type " + std::to_string((int)statementExpr->Type) + ")"));
}
namespace
{
}

#endif
