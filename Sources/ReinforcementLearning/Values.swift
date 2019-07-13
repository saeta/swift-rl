// Copyright 2019, Emmanouil Antonios Platanios. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

import TensorFlow

/// Computes discounted returns.
///
/// Discounted returns are defined as follows:
/// `Q_t = \sum_{t'=t}^T gamma^{t'-t} * r_{t'} + gamma^{T-t+1} * finalValue`,
/// where `r_t` represents the reward at time step `t` and `gamma` represents the discount factor.
/// For more details refer to "Reinforcement Learning: An Introduction" Second Edition by
/// Richard S. Sutton and Andrew G. Barto.
///
/// The discounted return computation also takes into account the time steps when episodes end
/// (i.e., steps whose kind is `.last`) by making sure to reset the discounted return being carried
/// backwards through time.
///
/// Typically, each reward tensor will have shape `[BatchSize]` (for batched rewards) or `[]` (for
/// unbatched rewards).
///
/// - Parameters:
///   - discountFactor: Reward discount factor (`gamma` in the above example).
///   - stepKinds: Contains the step kinds (represented using their integer values) for each step.
///   - rewards: Contains the rewards for each step.
///   - finalValue: Estimated value at the final step. This is used to bootstrap the reward-to-go
///     computation. Defaults to zeros.
///
/// - Returns: Array of discounted return values over time.
@inlinable
public func discountedReturns<Scalar: TensorFlowNumeric>(
  discountFactor: Scalar,
  stepKinds: StepKind,
  rewards: Tensor<Scalar>,
  finalValue: Tensor<Scalar>? = nil
) -> Tensor<Scalar> {
  let isLast = stepKinds.isLast()
  let T = stepKinds.rawValue.shape[0]
  let finalReward = finalValue ?? Tensor<Scalar>(zerosLike: rewards[0])
  var discountedReturns = [Tensor<Scalar>]()
  for t in 0..<T {
    let futureReturn = T - t < T ? discountedReturns[t - 1] : finalReward
    let discountedFutureReturn = discountFactor * futureReturn
    let discountedReturn = rewards[T - t - 1] + discountedFutureReturn.replacing(
      with: Tensor<Scalar>(zerosLike: discountedFutureReturn),
      where: isLast[T - t - 1])
    discountedReturns.append(discountedReturn)
  }
  return Tensor<Scalar>(stacking: discountedReturns.reversed())

  // TODO: !!! The following only considers the first episode for each batch element.
  // let rewardShape = TensorShape(rewards.rank > 1 ? rewards.shape.dimensions[1...] : [])
  // let finalReward = finalValue?.broadcasted(to: rewardShape) ?? Tensor<Scalar>(zeros: rewardShape)
  // let r = rewards.concatenated(with: finalReward.expandingShape(at: 0), alongAxis: 0)
  // let dd = Tensor<Scalar>(repeating: discountFactor, shape: rewards.shape).replacing(
  //   with: Tensor<Scalar>(zeros: rewards.shape),
  //   where: stepKinds.rawValue .== StepKind.last.rawValue.scalar!) // This will not currently work.
  // let ddOne = Tensor<Scalar>(repeating: discountFactor, shape: rewardShape).expandingShape(at: 0)
  // let discounts = dd.concatenated(with: ddOne, alongAxis: 0)
  // let d = discounts.cumulativeProduct(alongAxis: 0, exclusive: true)
  // let rPrime = (r * d).cumulativeSum(alongAxis: 0, reverse: true)
  // let rDiscounted = rPrime / d
  // return rDiscounted[0..<rewards.shape[0]]
}

public protocol AdvantageFunction {
  /// - Parameters:
  ///   - stepKinds: Contains the step kinds (represented using their integer values) for each step.
  ///   - returns: Contains the returns for each step.
  ///   - values: Contains the value estimates for each step.
  ///   - finalValue: Estimated value at the final step.
  func callAsFunction<Scalar: TensorFlowFloatingPoint>(
    stepKinds: StepKind,
    returns: Tensor<Scalar>,
    values: Tensor<Scalar>,
    finalValue: Tensor<Scalar>
  ) -> Tensor<Scalar>
}

// TODO: Remove once optionals are differentiable.
public struct NoAdvantageFunction: AdvantageFunction {
  public init() {}

  @inlinable
  public func callAsFunction<Scalar: TensorFlowFloatingPoint>(
    stepKinds: StepKind,
    returns: Tensor<Scalar>,
    values: Tensor<Scalar>,
    finalValue: Tensor<Scalar>
  ) -> Tensor<Scalar> {
    returns
  }
}

/// Performs empirical advantage estimation.
///
/// The empirical advantage estimate at step `t` is defined as:
/// `advantage[t] = reward[t] - value[t]`.
public struct EmpiricalAdvantageEstimation: AdvantageFunction {
  public init() {}

  /// - Parameters:
  ///   - stepKinds: Contains the step kinds (represented using their integer values) for each step.
  ///   - returns: Contains the returns for each step. These are typically already discounted
  ///     (i.e., the result of calling
  ///     `discountedReturns(discountFactor:stepKinds:rewards:finalValue:)`).
  ///   - values: Contains the value estimates for each step.
  ///   - finalValue: Estimated value at the final step.
  @inlinable
  public func callAsFunction<Scalar: TensorFlowFloatingPoint>(
    stepKinds: StepKind,
    returns: Tensor<Scalar>,
    values: Tensor<Scalar>,
    finalValue: Tensor<Scalar>
  ) -> Tensor<Scalar> {
    returns - values
  }
}

/// Performs generalized advantage estimation.
///
/// For more details refer to "High-Dimensional Continuous Control Using Generalized Advantage
/// Estimation" by John Schulman, Philipp Moritz et al. The full paper can be found at:
/// https://arxiv.org/abs/1506.02438.
public struct GeneralizedAdvantageEstimation: AdvantageFunction {
  public let discountFactor: Float
  public let discountWeight: Float

  /// - Parameters:
  ///   - discountFactor: Return discount factor value, which must be between `0.0` and `1.0`.
  ///   - discountWeight: A weight between `0.0` and `1.0` that is used for variance reduction in 
  ///     the temporal differences.
  public init(discountFactor: Float, discountWeight: Float = 1) {
    self.discountFactor = discountFactor
    self.discountWeight = discountWeight
  }

  /// - Parameters:
  ///   - stepKinds: Contains the step kinds (represented using their integer values) for each step.
  ///   - returns: Contains the returns for each step. These are typically already discounted
  ///     (i.e., the result of calling `discount(discountFactor:stepKinds:returns:finalValue:)`).
  ///   - values: Contains the value estimates for each step.
  ///   - finalValue: Estimated value at the final step.
  @inlinable
  public func callAsFunction<Scalar: TensorFlowFloatingPoint>(
    stepKinds: StepKind,
    returns: Tensor<Scalar>,
    values: Tensor<Scalar>,
    finalValue: Tensor<Scalar>
  ) -> Tensor<Scalar> {
    let discountWeight = Scalar(self.discountWeight)
    let discountFactor = Scalar(self.discountFactor)
    let isLast = stepKinds.isLast()
    let T = stepKinds.rawValue.shape[0]
    var advantages = [Tensor<Scalar>]()
    for t in 0..<T {
      let nextValue = T - t < T ? values[T - t] : finalValue
      let delta = returns[T - t - 1] + discountFactor * nextValue - values[T - t - 1]
      if T - t < T {
        let nextAdvantage = advantages[t - 1].replacing(
          with: Tensor<Scalar>(zerosLike: advantages[t - 1]),
          where: isLast[T - t - 1])
        advantages.append(delta + discountWeight * discountFactor * nextAdvantage)
      } else {
        advantages.append(delta)
      }
    }
    return Tensor<Scalar>(advantages.reversed())
  }
}
